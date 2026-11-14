const DropTarget = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const GUID = windows.GUID;
const c = @import("c.zig");
const HRESULT = c.HRESULT;
const clipboard = @import("clipboard.zig");
const Surface = @import("Surface.zig");

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

const IID_IUnknown: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IID_IDropTarget: GUID = .{
    .Data1 = 0x00000122,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IDataObject = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDataObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDataObject) callconv(.winapi) u32,
        Release: *const fn (*IDataObject) callconv(.winapi) u32,
        GetData: *const fn (*IDataObject, *const c.FORMATETC, *c.STGMEDIUM) callconv(.winapi) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*IDataObject, *const c.FORMATETC) callconv(.winapi) HRESULT,
    };
};

const DropTargetVTable = extern struct {
    QueryInterface: *const fn (*DropTarget, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*DropTarget) callconv(.winapi) u32,
    Release: *const fn (*DropTarget) callconv(.winapi) u32,
    DragEnter: *const fn (*DropTarget, *IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
    DragOver: *const fn (*DropTarget, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
    DragLeave: *const fn (*DropTarget) callconv(.winapi) HRESULT,
    Drop: *const fn (*DropTarget, *IDataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
};

const vtable: DropTargetVTable = .{
    .QueryInterface = queryInterface,
    .AddRef = addRef,
    .Release = release,
    .DragEnter = dragEnter,
    .DragOver = dragOver,
    .DragLeave = dragLeave,
    .Drop = drop,
};

pub const Shell = enum {
    powershell,
    cmd,
};

lpVtbl: *const DropTargetVTable = &vtable,
ref_count: u32 = 1,
alloc: Allocator,
surface: ?*Surface,
supported: bool = false,

pub fn register(alloc: Allocator, surface: *Surface) ?*DropTarget {
    const hwnd = surface.hwnd orelse return null;
    const self = alloc.create(DropTarget) catch return null;
    self.* = .{
        .alloc = alloc,
        .surface = surface,
    };
    if (c.RegisterDragDrop(hwnd, self) < 0) {
        alloc.destroy(self);
        return null;
    }
    return self;
}

pub fn revoke(self: *DropTarget, hwnd: ?c.HWND) void {
    self.surface = null;
    if (hwnd) |h| {
        _ = c.RevokeDragDrop(h);
    }
    _ = release(self);
}

fn queryInterface(self: *DropTarget, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&IID_IUnknown)) or
        std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&IID_IDropTarget)))
    {
        ppv.* = self;
        _ = addRef(self);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

fn addRef(self: *DropTarget) callconv(.winapi) u32 {
    self.ref_count += 1;
    return self.ref_count;
}

fn release(self: *DropTarget) callconv(.winapi) u32 {
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    const remaining = self.ref_count;
    if (remaining == 0) {
        self.alloc.destroy(self);
    }
    return remaining;
}

fn formatEtc(cf: c.UINT) c.FORMATETC {
    return .{
        .cfFormat = @intCast(cf),
        .ptd = null,
        .dwAspect = c.DVASPECT_CONTENT,
        .lindex = -1,
        .tymed = c.TYMED_HGLOBAL,
    };
}

fn canDrop(data_obj: *IDataObject) bool {
    const fmt_hdrop = formatEtc(c.CF_HDROP);
    if (data_obj.lpVtbl.QueryGetData(data_obj, &fmt_hdrop) == S_OK) return true;
    const fmt_text = formatEtc(c.CF_UNICODETEXT);
    if (data_obj.lpVtbl.QueryGetData(data_obj, &fmt_text) == S_OK) return true;
    return false;
}

fn dragEnter(
    self: *DropTarget,
    data_obj: *IDataObject,
    _: c.DWORD,
    _: c.POINTL,
    effect: *c.DWORD,
) callconv(.winapi) HRESULT {
    self.supported = canDrop(data_obj);
    effect.* = if (self.supported) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
    return S_OK;
}

fn dragOver(
    self: *DropTarget,
    _: c.DWORD,
    _: c.POINTL,
    effect: *c.DWORD,
) callconv(.winapi) HRESULT {
    effect.* = if (self.supported) c.DROPEFFECT_COPY else c.DROPEFFECT_NONE;
    return S_OK;
}

fn dragLeave(self: *DropTarget) callconv(.winapi) HRESULT {
    self.supported = false;
    return S_OK;
}

fn drop(
    self: *DropTarget,
    data_obj: *IDataObject,
    _: c.DWORD,
    _: c.POINTL,
    effect: *c.DWORD,
) callconv(.winapi) HRESULT {
    self.supported = false;
    const surface = self.surface orelse {
        effect.* = c.DROPEFFECT_NONE;
        return S_OK;
    };

    if (self.dropFiles(surface, data_obj)) {
        effect.* = c.DROPEFFECT_COPY;
        return S_OK;
    }

    if (self.dropText(surface, data_obj)) {
        effect.* = c.DROPEFFECT_COPY;
        return S_OK;
    }

    effect.* = c.DROPEFFECT_NONE;
    return S_OK;
}

fn dropFiles(self: *DropTarget, surface: *Surface, data_obj: *IDataObject) bool {
    const fmt = formatEtc(c.CF_HDROP);
    var med: c.STGMEDIUM = .{};
    if (data_obj.lpVtbl.GetData(data_obj, &fmt, &med) < 0) return false;
    defer c.ReleaseStgMedium(&med);

    const hglobal = med.hGlobal orelse return false;
    const locked = c.GlobalLock(hglobal) orelse return false;
    defer _ = c.GlobalUnlock(hglobal);

    const hdrop: c.HDROP = @ptrCast(locked);
    const count = c.DragQueryFileW(hdrop, 0xFFFF_FFFF, null, 0);
    if (count == 0) return false;

    const shell: Shell = if (surface.shellIsCmd()) .cmd else .powershell;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.alloc);

    var i: c.UINT = 0;
    while (i < count) : (i += 1) {
        const cch = c.DragQueryFileW(hdrop, i, null, 0);
        if (cch == 0) continue;
        const wide = self.alloc.alloc(u16, cch + 1) catch return false;
        defer self.alloc.free(wide);
        const copied = c.DragQueryFileW(hdrop, i, wide.ptr, cch + 1);
        if (copied == 0) continue;

        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.alloc, wide[0..copied]) catch return false;
        defer self.alloc.free(utf8);

        if (out.items.len > 0) out.append(self.alloc, ' ') catch return false;
        appendPath(self.alloc, &out, utf8, shell) catch return false;
    }

    if (out.items.len == 0) return false;
    surface.present();
    surface.pasteDroppedText(out.items);
    return true;
}

fn dropText(self: *DropTarget, surface: *Surface, data_obj: *IDataObject) bool {
    const fmt = formatEtc(c.CF_UNICODETEXT);
    var med: c.STGMEDIUM = .{};
    if (data_obj.lpVtbl.GetData(data_obj, &fmt, &med) < 0) return false;
    defer c.ReleaseStgMedium(&med);

    const hglobal = med.hGlobal orelse return false;
    const ptr: [*]const u16 = @ptrCast(@alignCast(c.GlobalLock(hglobal) orelse return false));
    defer _ = c.GlobalUnlock(hglobal);

    const units = ptr[0 .. c.GlobalSize(hglobal) / 2];
    const len = std.mem.indexOfScalar(u16, units, 0) orelse units.len;
    const text = clipboard.pasteTextFromUtf16(self.alloc, units[0..len]) catch return false;
    defer self.alloc.free(text);
    if (text.len == 0) return false;

    surface.present();
    surface.pasteDroppedText(text);
    return true;
}

fn isPowershellSingleQuoteUtf8(bytes: []const u8) bool {
    return bytes.len >= 3 and
        bytes[0] == 0xE2 and
        bytes[1] == 0x80 and
        (bytes[2] >= 0x98 and bytes[2] <= 0x9B);
}

fn needsQuoting(path: []const u8, shell: Shell) bool {
    if (path.len == 0) return true;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const ch = path[i];
        switch (shell) {
            .cmd => switch (ch) {
                ' ', '\t', '"', '&', '(', ')', '[', ']', '{', '}', '^', '=', ';', '!', '\'', '+', ',', '`', '~' => return true,
                else => {},
            },
            .powershell => {
                if (isPowershellSingleQuoteUtf8(path[i..])) return true;
                switch (ch) {
                    ' ', '\t', '\'', '"', '`', '$', ';', '&', '(', ')', '[', ']', '{', '}', '|', '<', '>', '@', '#', ',' => return true,
                    else => {},
                }
            },
        }
    }
    return false;
}

pub fn appendPath(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    path: []const u8,
    shell: Shell,
) Allocator.Error!void {
    if (!needsQuoting(path, shell)) {
        try out.appendSlice(alloc, path);
        return;
    }

    switch (shell) {
        .cmd => {
            try out.append(alloc, '"');
            for (path) |ch| {
                if (ch == '"') try out.append(alloc, '"');
                try out.append(alloc, ch);
            }
            try out.append(alloc, '"');
        },
        .powershell => {
            try out.append(alloc, '\'');
            var i: usize = 0;
            while (i < path.len) {
                if (path[i] == '\'') {
                    try out.appendSlice(alloc, "''");
                    i += 1;
                } else if (isPowershellSingleQuoteUtf8(path[i..])) {
                    try out.appendSlice(alloc, path[i .. i + 3]);
                    try out.appendSlice(alloc, path[i .. i + 3]);
                    i += 3;
                } else {
                    try out.append(alloc, path[i]);
                    i += 1;
                }
            }
            try out.append(alloc, '\'');
        },
    }
}

test "appendPath cmd and powershell quoting" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, "C:\\Users\\Ray\\file.txt", .powershell);
        try testing.expectEqualStrings("C:\\Users\\Ray\\file.txt", out.items);
    }

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, "C:\\Program Files\\Ghostty\\ghostty.exe", .powershell);
        try testing.expectEqualStrings("'C:\\Program Files\\Ghostty\\ghostty.exe'", out.items);
    }

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, "C:\\Users\\Ray's Docs\\$env\u{2019}s.txt", .powershell);
        try testing.expectEqualStrings("'C:\\Users\\Ray''s Docs\\$env\u{2019}\u{2019}s.txt'", out.items);
    }

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, "C:\\Program Files\\Ghostty\\ghostty.exe", .cmd);
        try testing.expectEqualStrings("\"C:\\Program Files\\Ghostty\\ghostty.exe\"", out.items);
    }

    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, "C:\\Users\\Ray\\a&b.txt", .cmd);
        try testing.expectEqualStrings("\"C:\\Users\\Ray\\a&b.txt\"", out.items);
    }
}
