//! DirectWrite COM vtable bindings for system font fallback on Windows.
//! Queries IDWriteFontFallback::MapCharacters to ask Windows which installed
//! font family it prefers for a given Unicode codepoint and locale.

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../os/windows.zig");
const global = @import("../global.zig");

pub const HRESULT = c_long;
pub const UINT32 = u32;
pub const FLOAT = f32;
pub const WCHAR = u16;
pub const BOOL = windows.BOOL;
pub const HMODULE = windows.HMODULE;
pub const GUID = windows.GUID;

// {B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}
pub const IID_IDWriteFactory = GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

// {0439FC60-CA44-4994-8DEE-3A9AF7B732EC}
pub const IID_IDWriteFactory2 = GUID{
    .Data1 = 0x0439fc60,
    .Data2 = 0xca44,
    .Data3 = 0x4994,
    .Data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec },
};

pub const DWRITE_FACTORY_TYPE = enum(u32) {
    SHARED = 0,
    ISOLATED = 1,
};

pub const DWRITE_FONT_WEIGHT = enum(u32) {
    NORMAL = 400,
    BOLD = 700,
    _,
};

pub const DWRITE_FONT_STYLE = enum(u32) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
};

pub const DWRITE_FONT_STRETCH = enum(u32) {
    NORMAL = 5,
    _,
};

pub const DWRITE_READING_DIRECTION = enum(u32) {
    LEFT_TO_RIGHT = 0,
    _,
};

pub const DWRITE_NUMBER_SUBSTITUTION_METHOD = enum(u32) {
    FROM_CULTURE = 0,
    _,
};

pub const IDWriteLocalizedStrings = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteLocalizedStrings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
        Release: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
        FindLocaleName: *const fn (*IDWriteLocalizedStrings, [*:0]const WCHAR, *u32, *BOOL) callconv(.winapi) HRESULT,
        GetLocaleNameLength: *const fn (*IDWriteLocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
        GetLocaleName: *const fn (*IDWriteLocalizedStrings, u32, [*]WCHAR, u32) callconv(.winapi) HRESULT,
        GetStringLength: *const fn (*IDWriteLocalizedStrings, u32, *u32) callconv(.winapi) HRESULT,
        GetString: *const fn (*IDWriteLocalizedStrings, u32, [*]WCHAR, u32) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteLocalizedStrings) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
        Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
        // IDWriteFontList methods
        GetFontCollection: *const anyopaque,
        GetFontCount: *const anyopaque,
        GetFont: *const anyopaque,
        // IDWriteFontFamily methods
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetFirstMatchingFont: *const anyopaque,
        GetMatchingFonts: *const anyopaque,
    };

    pub fn release(self: *IDWriteFontFamily) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFont = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFont, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFont) callconv(.winapi) u32,
        Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        GetWeight: *const anyopaque,
        GetStretch: *const anyopaque,
        GetStyle: *const anyopaque,
        IsSymbolFont: *const anyopaque,
        GetFaceNames: *const anyopaque,
        GetInformationalStrings: *const anyopaque,
        GetSimulations: *const anyopaque,
        GetMetrics: *const anyopaque,
        HasCharacter: *const fn (*IDWriteFont, u32, *BOOL) callconv(.winapi) HRESULT,
        CreateFontFace: *const anyopaque,
    };

    pub fn release(self: *IDWriteFont) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteTextAnalysisSource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteTextAnalysisSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
        Release: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
        GetTextAtPosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const WCHAR, *u32) callconv(.winapi) HRESULT,
        GetTextBeforePosition: *const fn (*IDWriteTextAnalysisSource, u32, *?[*]const WCHAR, *u32) callconv(.winapi) HRESULT,
        GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) DWRITE_READING_DIRECTION,
        GetLocaleName: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?[*:0]const WCHAR) callconv(.winapi) HRESULT,
        GetNumberSubstitution: *const fn (*IDWriteTextAnalysisSource, u32, *u32, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

pub const IDWriteFontFallback = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDWriteFontFallback, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFallback) callconv(.winapi) u32,
        Release: *const fn (*IDWriteFontFallback) callconv(.winapi) u32,
        MapCharacters: *const fn (
            *IDWriteFontFallback,
            *IDWriteTextAnalysisSource,
            u32,
            u32,
            ?*anyopaque,
            ?[*:0]const WCHAR,
            DWRITE_FONT_WEIGHT,
            DWRITE_FONT_STYLE,
            DWRITE_FONT_STRETCH,
            *u32,
            *?*IDWriteFont,
            *FLOAT,
        ) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDWriteFontFallback) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDWriteFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (*IDWriteFactory2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
        Release: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
        // IDWriteFactory (3..23)
        GetSystemFontCollection: *const anyopaque,
        CreateCustomFontCollection: *const anyopaque,
        RegisterFontCollectionLoader: *const anyopaque,
        UnregisterFontCollectionLoader: *const anyopaque,
        CreateFontFileReference: *const anyopaque,
        CreateCustomFontFileReference: *const anyopaque,
        CreateFontFace: *const anyopaque,
        CreateRenderingParams: *const anyopaque,
        CreateMonitorRenderingParams: *const anyopaque,
        CreateCustomRenderingParams: *const anyopaque,
        RegisterFontFileLoader: *const anyopaque,
        UnregisterFontFileLoader: *const anyopaque,
        CreateTextFormat: *const anyopaque,
        CreateTypography: *const anyopaque,
        GetGdiInterop: *const anyopaque,
        CreateTextLayout: *const anyopaque,
        CreateGdiCompatibleTextLayout: *const anyopaque,
        CreateEllipsisTrimmingSign: *const anyopaque,
        CreateTextAnalyzer: *const anyopaque,
        CreateNumberSubstitution: *const anyopaque,
        CreateGlyphRunAnalysis: *const anyopaque,
        // IDWriteFactory1 (24..25)
        GetEudcFontCollection: *const anyopaque,
        CreateCustomRenderingParams1: *const anyopaque,
        // IDWriteFactory2 (26..30)
        GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
        CreateFontFallbackBuilder: *const anyopaque,
        TranslateColorGlyphRun: *const anyopaque,
        CreateCustomRenderingParams2: *const anyopaque,
        CreateGlyphRunAnalysis2: *const anyopaque,
    };

    pub fn release(self: *IDWriteFactory2) void {
        _ = self.vtable.Release(self);
    }
};

pub const StackAnalysisSource = extern struct {
    base: IDWriteTextAnalysisSource = .{ .vtable = &vtable_impl },
    text: [2]WCHAR = .{ 0, 0 },
    len: u32 = 0,
    locale: [*:0]const WCHAR = std.unicode.utf8ToUtf16LeStringLiteral("en-US"),

    const vtable_impl: IDWriteTextAnalysisSource.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = getParagraphReadingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };

    pub fn init(cp: u32) StackAnalysisSource {
        var s: StackAnalysisSource = .{};
        if (cp < 0x10000) {
            s.text[0] = @intCast(cp);
            s.len = 1;
        } else if (cp <= 0x10FFFF) {
            const v = cp - 0x10000;
            s.text[0] = @intCast(0xD800 + (v >> 10));
            s.text[1] = @intCast(0xDC00 + (v & 0x3FF));
            s.len = 2;
        }
        return s;
    }

    fn selfFromBase(base: *IDWriteTextAnalysisSource) *StackAnalysisSource {
        return @alignCast(@fieldParentPtr("base", base));
    }

    fn queryInterface(_: *IDWriteTextAnalysisSource, _: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }

    fn addRef(_: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        return 1;
    }

    fn getTextAtPosition(base: *IDWriteTextAnalysisSource, pos: u32, text: *?[*]const WCHAR, len: *u32) callconv(.winapi) HRESULT {
        const self = selfFromBase(base);
        if (pos >= self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = self.text[pos..].ptr;
            len.* = self.len - pos;
        }
        return 0;
    }

    fn getTextBeforePosition(base: *IDWriteTextAnalysisSource, pos: u32, text: *?[*]const WCHAR, len: *u32) callconv(.winapi) HRESULT {
        const self = selfFromBase(base);
        if (pos == 0 or pos > self.len) {
            text.* = null;
            len.* = 0;
        } else {
            text.* = &self.text;
            len.* = pos;
        }
        return 0;
    }

    fn getParagraphReadingDirection(_: *IDWriteTextAnalysisSource) callconv(.winapi) DWRITE_READING_DIRECTION {
        return .LEFT_TO_RIGHT;
    }

    fn getLocaleName(base: *IDWriteTextAnalysisSource, pos: u32, len: *u32, locale: *?[*:0]const WCHAR) callconv(.winapi) HRESULT {
        const self = selfFromBase(base);
        len.* = if (pos < self.len) self.len - pos else 0;
        locale.* = self.locale;
        return 0;
    }

    fn getNumberSubstitution(_: *IDWriteTextAnalysisSource, pos: u32, len: *u32, sub: *?*anyopaque) callconv(.winapi) HRESULT {
        _ = pos;
        len.* = 0;
        sub.* = null;
        return 0;
    }
};

const DWriteCreateFactoryFn = *const fn (
    factory_type: DWRITE_FACTORY_TYPE,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

var dwrite_lock: std.Io.Mutex = .init;
var cached_fallback: ?*IDWriteFontFallback = null;
var dwrite_init_failed: bool = false;

fn getSystemFontFallback() ?*IDWriteFontFallback {
    dwrite_lock.lockUncancelable(global.io());
    defer dwrite_lock.unlock(global.io());
    if (cached_fallback) |fb| return fb;
    if (dwrite_init_failed) return null;

    const dwrite_mod = windows.exp.kernel32.LoadLibraryExW(
        std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll"),
        null,
        windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
    ) orelse {
        dwrite_init_failed = true;
        return null;
    };
    const create_fn_ptr = windows.exp.kernel32.GetProcAddress(dwrite_mod, "DWriteCreateFactory") orelse {
        dwrite_init_failed = true;
        return null;
    };
    const createFactory: DWriteCreateFactoryFn = @ptrCast(create_fn_ptr);

    var raw_factory: ?*anyopaque = null;
    if (createFactory(.SHARED, &IID_IDWriteFactory2, &raw_factory) < 0) {
        dwrite_init_failed = true;
        return null;
    }
    const factory: *IDWriteFactory2 = @ptrCast(@alignCast(raw_factory orelse {
        dwrite_init_failed = true;
        return null;
    }));
    defer factory.release();

    var fallback_opt: ?*IDWriteFontFallback = null;
    if (factory.vtable.GetSystemFontFallback(factory, &fallback_opt) < 0 or fallback_opt == null) {
        dwrite_init_failed = true;
        return null;
    }
    cached_fallback = fallback_opt;
    return fallback_opt;
}

/// Queries DirectWrite's system font fallback for `cp` and writes the
/// UTF-8 family name into `out_buf` if a match is found.
pub fn mapCodepointFamily(
    cp: u32,
    bold: bool,
    italic: bool,
    out_buf: []u8,
) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    if (cp == 0 or cp > 0x10FFFF) return null;

    const fallback = getSystemFontFallback() orelse return null;

    var source = StackAnalysisSource.init(cp);
    var mapped_len: u32 = 0;
    var mapped_font_opt: ?*IDWriteFont = null;
    var scale: FLOAT = 1.0;
    const hr = fallback.vtable.MapCharacters(
        fallback,
        &source.base,
        0,
        source.len,
        null,
        null,
        if (bold) .BOLD else .NORMAL,
        if (italic) .ITALIC else .NORMAL,
        .NORMAL,
        &mapped_len,
        &mapped_font_opt,
        &scale,
    );
    if (hr < 0) return null;
    const mapped_font = mapped_font_opt orelse return null;
    defer mapped_font.release();

    var family_opt: ?*IDWriteFontFamily = null;
    if (mapped_font.vtable.GetFontFamily(mapped_font, &family_opt) < 0) return null;
    const family = family_opt orelse return null;
    defer family.release();

    var names_opt: ?*IDWriteLocalizedStrings = null;
    if (family.vtable.GetFamilyNames(family, &names_opt) < 0) return null;
    const names = names_opt orelse return null;
    defer names.release();

    const count = names.vtable.GetCount(names);
    if (count == 0) return null;

    var idx: u32 = 0;
    var exists: BOOL = .FALSE;
    if (names.vtable.FindLocaleName(
        names,
        std.unicode.utf8ToUtf16LeStringLiteral("en-us"),
        &idx,
        &exists,
    ) < 0 or !exists.toBool()) {
        idx = 0;
    }

    var name_len: u32 = 0;
    if (names.vtable.GetStringLength(names, idx, &name_len) < 0 or name_len == 0 or name_len >= 256) return null;
    var wbuf: [256]WCHAR = undefined;
    if (names.vtable.GetString(names, idx, &wbuf, name_len + 1) < 0) return null;

    const utf8_len = std.unicode.utf16LeToUtf8(out_buf, wbuf[0..name_len]) catch return null;
    return out_buf[0..utf8_len];
}

test "StackAnalysisSource surrogate encoding" {
    const testing = std.testing;
    const s1 = StackAnalysisSource.init('A');
    try testing.expectEqual(@as(u32, 1), s1.len);
    try testing.expectEqual(@as(u16, 'A'), s1.text[0]);

    const s2 = StackAnalysisSource.init(0x1F600);
    try testing.expectEqual(@as(u32, 2), s2.len);
    try testing.expectEqual(@as(u16, 0xD83D), s2.text[0]);
    try testing.expectEqual(@as(u16, 0xDE00), s2.text[1]);
}
