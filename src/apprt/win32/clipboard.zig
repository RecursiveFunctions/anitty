const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const cf_html = @import("cf_html.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const replacement = std.unicode.replacement_character;

pub fn hasText() bool {
    return c.IsClipboardFormatAvailable(c.CF_UNICODETEXT).toBool();
}

pub fn readText(alloc: Allocator, hwnd: ?c.HWND) !?[]u8 {
    try open(hwnd);
    defer _ = c.CloseClipboard();
    const mem = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr: [*]const u16 = @ptrCast(@alignCast(c.GlobalLock(mem) orelse return null));
    defer _ = c.GlobalUnlock(mem);
    const units = ptr[0 .. c.GlobalSize(mem) / 2];
    const len = std.mem.indexOfScalar(u16, units, 0) orelse units.len;
    const text = try pasteTextFromUtf16(alloc, units[0..len]);
    if (text.len == 0) {
        alloc.free(text);
        return null;
    }
    return text;
}

pub fn writeText(alloc: Allocator, hwnd: ?c.HWND, text: []const u8) !void {
    try writeTextAndHtml(alloc, hwnd, text, null);
}

pub fn writeTextAndHtml(
    alloc: Allocator,
    hwnd: ?c.HWND,
    text: ?[]const u8,
    html: ?[]const u8,
) !void {
    if (text == null and html == null) return;

    var text_mem: ?c.HGLOBAL = null;
    var text_owned = false;
    defer if (!text_owned) if (text_mem) |m| {
        _ = c.GlobalFree(m);
    };

    if (text) |plain| {
        const wide = try utf16FromUtf8(alloc, plain);
        defer alloc.free(wide);
        const units = wide.len + 1;
        const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, units * 2) orelse return error.OutOfMemory;
        text_mem = mem;
        const dst: [*]u16 = @ptrCast(@alignCast(c.GlobalLock(mem) orelse return error.OutOfMemory));
        @memcpy(dst[0..units], wide.ptr[0..units]);
        _ = c.GlobalUnlock(mem);
    }

    var html_mem: ?c.HGLOBAL = null;
    var html_owned = false;
    var html_fmt: c.UINT = 0;
    defer if (!html_owned) if (html_mem) |m| {
        _ = c.GlobalFree(m);
    };

    if (html) |fragment| {
        html_fmt = c.RegisterClipboardFormatW(L("HTML Format"));
        if (html_fmt != 0) {
            const payload = try cf_html.encode(alloc, fragment);
            defer alloc.free(payload);
            const bytes = payload.len + 1;
            const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
            html_mem = mem;
            const dst: [*]u8 = @ptrCast(c.GlobalLock(mem) orelse return error.OutOfMemory);
            @memcpy(dst[0..bytes], payload.ptr[0..bytes]);
            _ = c.GlobalUnlock(mem);
        }
    }

    try open(hwnd);
    defer _ = c.CloseClipboard();
    if (!c.EmptyClipboard().toBool()) return error.ClipboardWriteFailed;

    if (text_mem) |mem| {
        if (c.SetClipboardData(c.CF_UNICODETEXT, mem) == null) return error.ClipboardWriteFailed;
        text_owned = true;
    }
    if (html_mem) |mem| {
        if (c.SetClipboardData(html_fmt, mem) != null) {
            html_owned = true;
        }
    }
}

fn open(hwnd: ?c.HWND) error{ClipboardBusy}!void {
    for (0..10) |_| {
        if (c.OpenClipboard(hwnd).toBool()) return;
        c.Sleep(10);
    }
    return error.ClipboardBusy;
}

pub fn utf16FromUtf8(alloc: Allocator, text: []const u8) ![:0]u16 {
    var list: std.ArrayList(u16) = .empty;
    errdefer list.deinit(alloc);
    try list.ensureTotalCapacity(alloc, text.len + 1);

    var i: usize = 0;
    while (i < text.len) {
        const cp: u21, const n: usize = decode: {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch
                break :decode .{ replacement, 1 };
            if (i + len > text.len) break :decode .{ replacement, 1 };
            const cp = std.unicode.utf8Decode(text[i..][0..len]) catch
                break :decode .{ replacement, 1 };
            break :decode .{ cp, len };
        };
        i += n;

        if (cp < 0x10000) {
            list.appendAssumeCapacity(@intCast(cp));
        } else {
            const v = cp - 0x10000;
            list.appendAssumeCapacity(@intCast(0xD800 + (v >> 10)));
            list.appendAssumeCapacity(@intCast(0xDC00 + (v & 0x3FF)));
        }
    }

    return try list.toOwnedSliceSentinel(alloc, 0);
}

pub fn pasteTextFromUtf16(alloc: Allocator, units: []const u16) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.ensureTotalCapacity(alloc, units.len * 3);

    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        if (u == '\r' and i + 1 < units.len and units[i + 1] == '\n') {
            i += 1;
            continue;
        }

        var cp: u21 = replacement;
        var n: usize = 1;
        if (std.unicode.utf16IsHighSurrogate(u)) {
            if (i + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[i + 1])) {
                cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10 | (@as(u21, units[i + 1]) - 0xDC00));
                n = 2;
            }
        } else if (!std.unicode.utf16IsLowSurrogate(u)) {
            cp = u;
        }
        i += n;

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        list.appendSliceAssumeCapacity(buf[0..len]);
    }

    return try list.toOwnedSlice(alloc);
}

test "utf8 to utf16" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const wide = try utf16FromUtf8(alloc, "héllo\nwörld 日本 🎉");
    defer alloc.free(wide);
    try testing.expectEqualSlices(u16, L("héllo\nwörld 日本 🎉"), wide);

    const bad = try utf16FromUtf8(alloc, "a\xffb\xe6\x97");
    defer alloc.free(bad);
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD, 0xFFFD }, bad);
}

test "utf16 to paste text" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const text = try pasteTextFromUtf16(alloc, L("héllo\r\nwörld\r日本\n🎉\r\n"));
    defer alloc.free(text);
    try testing.expectEqualStrings("héllo\nwörld\r日本\n🎉\n", text);

    const bad = try pasteTextFromUtf16(alloc, &.{ 'a', 0xD800, 'b', 0xDC00 });
    defer alloc.free(bad);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", bad);
}

test "clipboard round trip" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    if (@import("../../os/windows.zig").exp.kernel32.GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_TEST_CLIPBOARD"),
        null,
        0,
    ) == 0) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    const hwnd = c.CreateWindowExW(
        0,
        L("STATIC"),
        null,
        0,
        0,
        0,
        0,
        0,
        c.HWND_MESSAGE,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);

    var saved = try Saved.save(alloc, hwnd);
    defer saved.deinit(alloc);
    defer saved.restore(hwnd);

    try writeText(alloc, hwnd, "héllo\r\nwörld 日本 🎉");
    const text = (try readText(alloc, hwnd)).?;
    defer alloc.free(text);
    try testing.expectEqualStrings("héllo\nwörld 日本 🎉", text);
}

const Saved = struct {
    formats: std.ArrayList(c.UINT) = .empty,
    data: std.ArrayList([]u8) = .empty,

    fn save(alloc: Allocator, hwnd: c.HWND) !Saved {
        var self: Saved = .{};
        errdefer self.deinit(alloc);
        try open(hwnd);
        defer _ = c.CloseClipboard();

        var format: c.UINT = 0;
        while (true) {
            format = c.EnumClipboardFormats(format);
            if (format == 0) break;
            switch (format) {
                1, 7, 13, 16 => {},
                else => if (format < 0xC000) return error.SkipZigTest,
            }
            const mem = c.GetClipboardData(format) orelse continue;
            const ptr: [*]const u8 = @ptrCast(c.GlobalLock(mem) orelse continue);
            defer _ = c.GlobalUnlock(mem);
            const bytes = try alloc.dupe(u8, ptr[0..c.GlobalSize(mem)]);
            errdefer alloc.free(bytes);
            try self.formats.append(alloc, format);
            try self.data.append(alloc, bytes);
        }
        return self;
    }

    fn restore(self: *const Saved, hwnd: c.HWND) void {
        open(hwnd) catch return;
        defer _ = c.CloseClipboard();
        _ = c.EmptyClipboard();
        for (self.formats.items, self.data.items) |format, bytes| {
            const mem = c.GlobalAlloc(c.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse continue;
            const dst: [*]u8 = @ptrCast(c.GlobalLock(mem) orelse {
                _ = c.GlobalFree(mem);
                continue;
            });
            @memcpy(dst[0..bytes.len], bytes);
            _ = c.GlobalUnlock(mem);
            if (c.SetClipboardData(format, mem) == null) _ = c.GlobalFree(mem);
        }
    }

    fn deinit(self: *Saved, alloc: Allocator) void {
        for (self.data.items) |bytes| alloc.free(bytes);
        self.data.deinit(alloc);
        self.formats.deinit(alloc);
    }
};
