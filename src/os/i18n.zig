const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");
const internal_os = @import("main.zig");
const locales = @import("i18n_locales.zig").locales;

const log = std.log.scoped(.i18n);

var windows_mo_data: ?[]const u8 = null;

/// Set for faster membership lookup of locales.
pub const locales_map = map: {
    var kvs: [locales.len]struct { []const u8 } = undefined;
    for (locales, 0..) |locale, i| kvs[i] = .{locale};
    break :map std.StaticStringMap(void).initComptime(kvs);
};

pub const InitError = error{
    InvalidResourcesDir,
    OutOfMemory,
};

/// Initialize i18n support for the application. This should be
/// called automatically by the global state initialization
/// in global.zig.
///
/// This calls `bindtextdomain` for gettext with the proper directory
/// of translations. This does NOT call `textdomain` as we don't
/// want to set the domain for the entire application since this is also
/// used by libghostty.
pub fn init(resources_dir: []const u8) InitError!void {
    if (comptime !build_config.i18n) return;

    switch (builtin.target.os.tag) {
        .windows => try initWindows(resources_dir),

        else => {
            // Our resources dir is always nested below the share dir that
            // is standard for translations.
            const share_dir = std.fs.path.dirname(resources_dir) orelse
                return error.InvalidResourcesDir;

            // Build our locale path
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.mem.printSentinel(&buf, "{s}/locale", .{share_dir}, 0) catch
                return error.OutOfMemory;

            // Bind our bundle ID to the given locale path
            log.debug("binding domain={s} path={s}", .{ build_config.bundle_id, path });
            _ = bindtextdomain(build_config.bundle_id, path.ptr) orelse
                return error.OutOfMemory;
        },
    }
}

fn initWindows(resources_dir: []const u8) InitError!void {
    const share_dir = std.fs.path.dirname(resources_dir) orelse
        return error.InvalidResourcesDir;

    var env_buf: [256]u8 = undefined;
    const raw_locale = readWindowsLocaleEnv(&env_buf) orelse return;
    const matched = matchSupportedLocaleList(raw_locale) orelse return;

    const alloc = global.alloc();
    const mo_path = std.fs.path.join(alloc, &.{
        share_dir,
        "locale",
        matched,
        "LC_MESSAGES",
        "com.mitchellh.ghostty.mo",
    }) catch return error.OutOfMemory;
    defer alloc.free(mo_path);

    const data = std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        mo_path,
        alloc,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        log.debug("no translation catalog loaded path={s} err={}", .{ mo_path, err });
        return;
    };

    if (windows_mo_data) |old| alloc.free(old);
    windows_mo_data = data;
    log.info("loaded Windows translation catalog locale={s} bytes={d}", .{ matched, data.len });
}

fn readWindowsLocaleEnv(buf: []u8) ?[]const u8 {
    if (comptime builtin.target.os.tag != .windows) return null;
    const windows = internal_os.windows;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const keys = [_][:0]const u16{
        L("LANGUAGE"),
        L("LC_ALL"),
        L("LC_MESSAGES"),
        L("LANG"),
    };
    var wide_buf: [128]u16 = undefined;
    for (keys) |key| {
        const len = windows.exp.kernel32.GetEnvironmentVariableW(key, &wide_buf, wide_buf.len);
        if (len > 0 and len < wide_buf.len) {
            const utf8_len = std.unicode.utf16LeToUtf8(buf, wide_buf[0..len]) catch continue;
            if (utf8_len > 0) return buf[0..utf8_len];
        }
    }
    const name_len = windows.exp.kernel32.GetUserDefaultLocaleName(&wide_buf, wide_buf.len);
    if (name_len > 1) {
        const utf8_len = std.unicode.utf16LeToUtf8(buf, wide_buf[0..@intCast(name_len - 1)]) catch return null;
        if (utf8_len > 0) return buf[0..utf8_len];
    }
    return null;
}

pub fn matchSupportedLocaleList(list: []const u8) ?[:0]const u8 {
    var it = std.mem.tokenizeScalar(u8, list, ':');
    while (it.next()) |item| {
        if (matchSupportedLocale(item)) |matched| return matched;
    }
    return null;
}

pub fn matchSupportedLocale(raw_locale: []const u8) ?[:0]const u8 {
    const trimmed = std.mem.trim(u8, raw_locale, " \t\r\n");
    if (trimmed.len == 0) return null;

    const dot = std.mem.indexOfScalar(u8, trimmed, '.') orelse trimmed.len;
    const without_enc = trimmed[0..dot];
    if (without_enc.len == 0) return null;

    var norm_buf: [64]u8 = undefined;
    const norm = normalizeLocale(&norm_buf, without_enc) catch return null;

    for (locales) |loc| {
        if (std.mem.eql(u8, loc, norm)) return loc;
    }

    const sep = std.mem.indexOfAny(u8, norm, "_@") orelse norm.len;
    const lang = norm[0..sep];
    if (lang.len == 0 or std.mem.eql(u8, lang, "en") or std.mem.eql(u8, lang, "C") or std.mem.eql(u8, lang, "POSIX")) {
        return null;
    }

    for (locales) |loc| {
        if (std.mem.eql(u8, loc, lang)) return loc;
    }
    for (locales) |loc| {
        if (loc.len > lang.len and std.mem.startsWith(u8, loc, lang) and (loc[lang.len] == '_' or loc[lang.len] == '@')) {
            return loc;
        }
    }
    return null;
}

pub fn lookupMo(mo_bytes: []const u8, msgid: [*:0]const u8) ?[*:0]const u8 {
    if (mo_bytes.len < 28) return null;
    const magic = std.mem.readInt(u32, mo_bytes[0..4], .little);
    if (magic != 0x950412de) return null;
    const count = std.mem.readInt(u32, mo_bytes[8..12], .little);
    const orig_table_off = std.mem.readInt(u32, mo_bytes[12..16], .little);
    const trans_table_off = std.mem.readInt(u32, mo_bytes[16..20], .little);
    if (count == 0) return null;
    if (@as(u64, orig_table_off) + @as(u64, count) * 8 > mo_bytes.len) return null;
    if (@as(u64, trans_table_off) + @as(u64, count) * 8 > mo_bytes.len) return null;

    const needle = std.mem.sliceTo(msgid, 0);
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry_off = orig_table_off + mid * 8;
        const orig_len = std.mem.readInt(u32, mo_bytes[entry_off..][0..4], .little);
        const orig_str_off = std.mem.readInt(u32, mo_bytes[entry_off + 4 ..][0..4], .little);
        if (@as(u64, orig_str_off) + @as(u64, orig_len) >= mo_bytes.len) return null;
        const cand = mo_bytes[orig_str_off .. orig_str_off + orig_len];
        switch (std.mem.order(u8, needle, cand)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => {
                const t_entry_off = trans_table_off + mid * 8;
                const t_len = std.mem.readInt(u32, mo_bytes[t_entry_off..][0..4], .little);
                const t_str_off = std.mem.readInt(u32, mo_bytes[t_entry_off + 4 ..][0..4], .little);
                if (t_len == 0) return null;
                if (@as(u64, t_str_off) + @as(u64, t_len) >= mo_bytes.len) return null;
                if (mo_bytes[t_str_off + t_len] != 0) return null;
                return @ptrCast(mo_bytes.ptr + t_str_off);
            },
        }
    }
    return null;
}

/// Set the global gettext domain to our bundle ID, allowing unqualified
/// `gettext` (`_`) calls to look up translations for our application.
///
/// This should only be called for apprts that are fully owning the
/// Ghostty application. This should not be called for libghostty users.
pub fn initGlobalDomain() error{OutOfMemory}!void {
    if (comptime !build_config.i18n or builtin.target.os.tag == .windows) return;
    _ = textdomain(build_config.bundle_id) orelse return error.OutOfMemory;
}

/// Translate a message for the Ghostty domain.
///
/// If this is called at comptime, the direct msgid is returned without
/// translation. This still allows the string to be marked for translation
/// while remaining usable in comptime contexts.
pub fn _(msgid: [*:0]const u8) [*:0]const u8 {
    if (comptime !build_config.i18n) return msgid;
    if (@inComptime()) return msgid;
    if (comptime builtin.target.os.tag == .windows) {
        const mo = windows_mo_data orelse return msgid;
        return lookupMo(mo, msgid) orelse msgid;
    }
    return dgettext(build_config.bundle_id, msgid);
}

/// Mark a string for translation without translating it immediately.
pub fn N_(msgid: [:0]const u8) [:0]const u8 {
    return msgid;
}

/// Canonicalize a locale name from a platform-specific value to
/// a POSIX-compliant value. This is a thin layer over the unexported
/// gnulib-lib function in gettext that does this already.
///
/// The gnulib-lib function modifies the buffer in place but has
/// zero bounds checking, so we do a bit extra to ensure we don't
/// overflow the buffer. This is likely slightly more expensive but
/// this isn't a hot path so it should be fine.
///
/// The buffer must be at least 16 bytes long. This ensures we can
/// fit the longest possible hardcoded locale name. Additionally,
/// it should be at least as long as locale in case the locale
/// is unchanged.
///
/// Here is the logic for macOS, but other platforms also have
/// their own canonicalization logic:
///
/// https://github.com/coreutils/gnulib/blob/5b92dd0a45c8d27f13a21076b57095ea5e220870/lib/localename.c#L1171
fn normalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }
    if (buf.len < locale.len + 1) return error.NoSpaceLeft;
    for (locale, 0..) |ch, i| {
        buf[i] = if (ch == '-') '_' else ch;
    }
    buf[locale.len] = 0;
    return buf[0..locale.len :0];
}

pub fn canonicalizeLocale(
    buf: []u8,
    locale: []const u8,
) error{NoSpaceLeft}![:0]const u8 {
    if (comptime !build_config.i18n or builtin.target.os.tag == .windows) {
        return normalizeLocale(buf, locale);
    }

    // Fix zh locales for macOS
    if (fixZhLocale(locale)) |fixed| {
        if (buf.len < fixed.len + 1) return error.NoSpaceLeft;
        @memcpy(buf[0..fixed.len], fixed);
        buf[fixed.len] = 0;
        return buf[0..fixed.len :0];
    }

    // Buffer must be 16 or at least as long as the locale and null term
    if (buf.len < @max(16, locale.len + 1)) return error.NoSpaceLeft;

    // Copy our locale into the buffer since it modifies in place.
    // This must be null-terminated.
    @memcpy(buf[0..locale.len], locale);
    buf[locale.len] = 0;

    _libintl_locale_name_canonicalize(buf[0..locale.len :0]);

    // Convert the null-terminated result buffer into a slice. We
    // need to search for the null terminator and slice it back.
    // We have to use `buf` since `slice` len will exclude the
    // null.
    const slice = std.mem.sliceTo(buf, 0);
    return buf[0..slice.len :0];
}

/// Handles some zh locales canonicalization because internal libintl
/// canonicalization function doesn't handle correctly in these cases.
fn fixZhLocale(locale: []const u8) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, locale, '-');
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "zh")) return null;

    const script = it.next() orelse return null;
    const region = it.next() orelse return null;

    if (std.mem.eql(u8, script, "Hans")) {
        if (std.mem.eql(u8, region, "SG")) return "zh_SG";
        return "zh_CN";
    }

    if (std.mem.eql(u8, script, "Hant")) {
        if (std.mem.eql(u8, region, "MO")) return "zh_MO";
        if (std.mem.eql(u8, region, "HK")) return "zh_HK";
        return "zh_TW";
    }

    return null;
}

/// This can be called at any point a compile-time-known locale is
/// available. This will use comptime to verify the locale is supported.
pub fn staticLocale(comptime v: [*:0]const u8) [*:0]const u8 {
    comptime {
        for (locales) |locale| {
            if (std.mem.eql(u8, locale, v)) {
                return locale;
            }
        }

        @compileError("unsupported locale");
    }
}

// Manually include function definitions for the gettext functions
// as libintl.h isn't always easily available (e.g. in musl)
extern fn bindtextdomain(domainname: [*:0]const u8, dirname: [*:0]const u8) ?[*:0]const u8;
extern fn textdomain(domainname: [*:0]const u8) ?[*:0]const u8;
extern fn dgettext(domainname: [*:0]const u8, msgid: [*:0]const u8) [*:0]const u8;

// This is only available if we're building libintl from source
// since its otherwise not exported. We only need it on macOS
// currently but probably will on Windows as well.
extern fn _libintl_locale_name_canonicalize(name: [*:0]u8) void;

test "canonicalizeLocale darwin" {
    if (!builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const testing = std.testing;
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("en_US", try canonicalizeLocale(&buf, "en_US"));
    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant"));

    try testing.expectEqualStrings("zh_CN", try canonicalizeLocale(&buf, "zh-Hans-CN"));
    try testing.expectEqualStrings("zh_SG", try canonicalizeLocale(&buf, "zh-Hans-SG"));
    try testing.expectEqualStrings("zh_TW", try canonicalizeLocale(&buf, "zh-Hant-TW"));
    try testing.expectEqualStrings("zh_HK", try canonicalizeLocale(&buf, "zh-Hant-HK"));
    try testing.expectEqualStrings("zh_MO", try canonicalizeLocale(&buf, "zh-Hant-MO"));

    // This is just an edge case I want to make sure we're aware of:
    // canonicalizeLocale does not handle encodings and will turn them into
    // underscores. We should parse them out before calling this function.
    try testing.expectEqualStrings("en_US.UTF_8", try canonicalizeLocale(&buf, "en_US.UTF-8"));
}

test "_ returns msgid at comptime" {
    const testing = std.testing;

    const msgid = comptime @"_"("Ghostty");
    try testing.expectEqualStrings("Ghostty", std.mem.span(msgid));
}

test "matchSupportedLocale" {
    const testing = std.testing;
    try testing.expectEqualStrings("ja", matchSupportedLocale("ja_JP.UTF-8").?);
    try testing.expectEqualStrings("de", matchSupportedLocale("de-DE").?);
    try testing.expectEqualStrings("zh_CN", matchSupportedLocale("zh-Hans-CN").?);
    try testing.expectEqualStrings("zh_TW", matchSupportedLocale("zh-Hant-TW").?);
    try testing.expectEqualStrings("pt_BR", matchSupportedLocale("pt_BR.UTF-8").?);
    try testing.expect(matchSupportedLocale("en_US.UTF-8") == null);
    try testing.expect(matchSupportedLocale("C") == null);
}

test "lookupMo binary catalog search" {
    const testing = std.testing;
    const po2mo = @import("../build/po2mo.zig");
    const sample_po =
        \\msgid ""
        \\msgstr ""
        \\"Content-Type: text/plain; charset=UTF-8\n"
        \\
        \\msgid "Close"
        \\msgstr "閉じる"
        \\
        \\msgid "Copy"
        \\msgstr "コピー"
        \\
        \\#, fuzzy
        \\msgid "FuzzyId"
        \\msgstr "ShouldBeSkipped"
        \\
    ;
    const mo_bytes = try po2mo.compilePoToMo(testing.allocator, sample_po);
    defer testing.allocator.free(mo_bytes);

    try testing.expectEqualStrings("閉じる", std.mem.span(lookupMo(mo_bytes, "Close").?));
    try testing.expectEqualStrings("コピー", std.mem.span(lookupMo(mo_bytes, "Copy").?));
    try testing.expect(lookupMo(mo_bytes, "FuzzyId") == null);
    try testing.expect(lookupMo(mo_bytes, "NonExistent") == null);
}
