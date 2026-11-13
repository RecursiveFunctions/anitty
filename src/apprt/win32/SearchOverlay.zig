const SearchOverlay = @This();

const std = @import("std");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const class_name = L("GhosttySearchOverlay");

const overlay_width = 320;
const overlay_height = 36;
const margin = 12;
const pad_x = 8;
const btn_size = 24;
const count_width = 64;
const edit_id: usize = 1;

pub const Corner = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    pub fn nearest(x: i32, y: i32, parent_w: i32, parent_h: i32) Corner {
        const right = x >= @divTrunc(parent_w, 2);
        const bottom = y >= @divTrunc(parent_h, 2);
        return if (bottom)
            (if (right) .bottom_right else .bottom_left)
        else
            (if (right) .top_right else .top_left);
    }
};

const Hit = enum {
    prev,
    next,
    close,
};

hwnd: ?c.HWND = null,
edit_hwnd: ?c.HWND = null,
orig_edit_proc: ?c.WNDPROC = null,
font: ?c.HFONT = null,
edit_brush: ?c.HBRUSH = null,
active: bool = false,
suppress_change: bool = false,
total: ?usize = null,
selected: ?usize = null,
corner: Corner = .top_right,
hover: ?Hit = null,
tracking: bool = false,
dragging: bool = false,
drag_offset: c.POINT = .{},

fn surface(self: *SearchOverlay) *Surface {
    return @alignCast(@fieldParentPtr("search_overlay", self));
}

fn scale(v: i32, dpi: c.UINT) i32 {
    return @intCast(@divTrunc(v * @as(i32, @intCast(dpi)), 96));
}

pub fn create(self: *SearchOverlay, parent: c.HWND, instance: ?c.HINSTANCE) !void {
    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;

    const edit = c.CreateWindowExW(
        0,
        L("EDIT"),
        L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(edit_id),
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    self.edit_hwnd = edit;
    _ = c.SetWindowLongPtrW(edit, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    const prev_proc = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editSubclassProc)));
    self.orig_edit_proc = @ptrFromInt(@as(usize, @bitCast(prev_proc)));

    self.updateFont();
}

pub fn updateFont(self: *SearchOverlay) void {
    const hwnd = self.hwnd orelse return;
    var ncm: c.NONCLIENTMETRICSW = .{};
    const dpi = c.GetDpiForWindow(hwnd);
    if (!c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi).toBool()) return;
    const font = c.CreateFontIndirectW(&ncm.lfMessageFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    if (self.edit_hwnd) |edit| {
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    self.layout();
    self.invalidate();
}

pub fn invalidate(self: *SearchOverlay) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn rectForCorner(corner: Corner, parent_w: i32, parent_h: i32, dpi: c.UINT, top_inset: i32) c.RECT {
    const w = @min(scale(overlay_width, dpi), @max(120, parent_w - scale(margin * 2, dpi)));
    const h = scale(overlay_height, dpi);
    const m = scale(margin, dpi);
    const left = switch (corner) {
        .top_left, .bottom_left => m,
        .top_right, .bottom_right => @max(m, parent_w - w - m),
    };
    const top = switch (corner) {
        .top_left, .top_right => top_inset + m,
        .bottom_left, .bottom_right => @max(top_inset + m, parent_h - h - m),
    };
    return .{
        .left = left,
        .top = top,
        .right = left + w,
        .bottom = top + h,
    };
}

pub fn layout(self: *SearchOverlay) void {
    const hwnd = self.hwnd orelse return;
    const s = self.surface();
    const dpi = c.GetDpiForWindow(hwnd);
    const top_inset = s.overlay.topBannerHeight(dpi);
    const r = rectForCorner(self.corner, @intCast(s.size.width), @intCast(s.size.height), dpi, top_inset);
    const w = r.right - r.left;
    const h = r.bottom - r.top;
    _ = c.SetWindowPos(
        hwnd,
        null,
        r.left,
        r.top,
        w,
        h,
        c.SWP_NOACTIVATE,
    );
    if (self.edit_hwnd) |edit| {
        const px = scale(pad_x, dpi);
        const bs = scale(btn_size, dpi);
        const cw = scale(count_width, dpi);
        const edit_w = @max(40, w - px * 2 - cw - bs * 3 - scale(8, dpi));
        const edit_h = @max(16, h - scale(14, dpi));
        const edit_y = @divTrunc(h - edit_h, 2);
        _ = c.MoveWindow(edit, px, edit_y, edit_w, edit_h, .TRUE);
    }
}

pub fn start(self: *SearchOverlay, needle: [:0]const u8) void {
    const hwnd = self.hwnd orelse return;
    const s = self.surface();
    const alloc = s.app.core_app.alloc;

    const was_active = self.active;
    self.active = true;
    s.overlay.layoutDim();
    self.layout();

    if (needle.len > 0) {
        if (std.unicode.utf8ToUtf16LeAllocZ(alloc, needle)) |wide| {
            defer alloc.free(wide);
            if (self.edit_hwnd) |edit| {
                self.suppress_change = true;
                _ = c.SetWindowTextW(edit, wide);
                self.suppress_change = false;
            }
        } else |_| {}
        self.notifyNeedle(needle);
    } else if (!was_active) {
        self.notifyCurrentText();
    }

    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    if (self.edit_hwnd) |edit| {
        _ = c.SetFocus(edit);
        _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    }
    self.invalidate();
}

pub fn end(self: *SearchOverlay) void {
    if (!self.active) return;
    self.active = false;
    self.total = null;
    self.selected = null;
    if (self.hwnd) |hwnd| _ = c.ShowWindow(hwnd, c.SW_HIDE);
    const s = self.surface();
    s.overlay.layoutDim();
    if (s.hwnd) |shwnd| _ = c.SetFocus(shwnd);
}

pub fn setTotal(self: *SearchOverlay, total: ?usize) void {
    if (self.total == total) return;
    self.total = total;
    self.invalidate();
}

pub fn setSelected(self: *SearchOverlay, selected: ?usize) void {
    if (self.selected == selected) return;
    self.selected = selected;
    self.invalidate();
}

pub fn formatCount(buf: []u8, selected: ?usize, total: ?usize) []const u8 {
    const t = total orelse return "";
    if (t == 0) return std.fmt.bufPrint(buf, "0/0", .{}) catch "";
    if (selected) |sel| {
        return std.fmt.bufPrint(buf, "{d}/{d}", .{ sel, t }) catch "";
    }
    return std.fmt.bufPrint(buf, "?/{d}", .{t}) catch "";
}

fn notifyNeedle(self: *SearchOverlay, needle: []const u8) void {
    const s = self.surface();
    if (!s.initialized) return;
    _ = s.core_surface.performBindingAction(.{ .search = needle }) catch |err| {
        log.warn("unable to perform search action err={}", .{err});
    };
}

fn notifyCurrentText(self: *SearchOverlay) void {
    const edit = self.edit_hwnd orelse return;
    const s = self.surface();
    const alloc = s.app.core_app.alloc;
    const len: usize = @intCast(@max(0, c.GetWindowTextLengthW(edit)));
    if (len == 0) {
        self.notifyNeedle("");
        return;
    }
    const wide = alloc.allocSentinel(u16, len, 0) catch return;
    defer alloc.free(wide);
    const n: usize = @intCast(@max(0, c.GetWindowTextW(edit, wide.ptr, @intCast(len + 1))));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..n]) catch return;
    defer alloc.free(utf8);
    self.notifyNeedle(utf8);
}

fn navigate(self: *SearchOverlay, next: bool) void {
    const s = self.surface();
    if (!s.initialized) return;
    _ = s.core_surface.performBindingAction(.{
        .navigate_search = if (next) .next else .previous,
    }) catch |err| {
        log.warn("unable to perform navigate_search err={}", .{err});
    };
}

fn stopSearch(self: *SearchOverlay) void {
    const s = self.surface();
    if (!s.initialized) return;
    _ = s.core_surface.performBindingAction(.end_search) catch |err| {
        log.warn("unable to perform end_search err={}", .{err});
    };
}

fn buttonRect(self: *const SearchOverlay, kind: Hit) c.RECT {
    const hwnd = self.hwnd orelse return .{};
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const dpi = c.GetDpiForWindow(hwnd);
    const bs = scale(btn_size, dpi);
    const px = scale(pad_x, dpi);
    const top = @divTrunc((r.bottom - r.top) - bs, 2);
    const idx: i32 = switch (kind) {
        .prev => 3,
        .next => 2,
        .close => 1,
    };
    const left = r.right - px - bs * idx;
    return .{ .left = left, .top = top, .right = left + bs, .bottom = top + bs };
}

fn hitAt(self: *const SearchOverlay, x: i32, y: i32) ?Hit {
    inline for (.{ Hit.prev, Hit.next, Hit.close }) |k| {
        const b = self.buttonRect(k);
        if (x >= b.left and x < b.right and y >= b.top and y < b.bottom) return k;
    }
    return null;
}

fn paint(self: *SearchOverlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;

    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, w, h) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer if (old_bmp) |o| {
        _ = c.SelectObject(mem, o);
    };
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |o| {
        _ = c.SelectObject(mem, o);
    };

    const s = self.surface();
    const palette = TabBar.Palette.init(&s.app.config);
    const dpi = c.GetDpiForWindow(hwnd);

    fill(mem, rect, palette.bar);
    drawBorder(mem, rect, palette.separator);

    _ = c.SetBkMode(mem, c.TRANSPARENT);
    _ = c.SetTextColor(mem, palette.text_inactive);

    var count_buf: [48]u8 = undefined;
    const count_str = formatCount(&count_buf, self.selected, self.total);
    if (count_str.len > 0) {
        const prev_r = self.buttonRect(.prev);
        var count_r: c.RECT = .{
            .left = prev_r.left - scale(count_width, dpi),
            .top = 0,
            .right = prev_r.left - scale(4, dpi),
            .bottom = h,
        };
        var wide_buf: [48]u16 = undefined;
        if (std.unicode.utf8ToUtf16Le(&wide_buf, count_str)) |n| {
            _ = c.DrawTextW(
                mem,
                &wide_buf,
                @intCast(n),
                &count_r,
                c.DT_SINGLELINE | c.DT_VCENTER | c.DT_RIGHT | c.DT_NOPREFIX,
            );
        } else |_| {}
    }

    inline for (.{ Hit.prev, Hit.next, Hit.close }) |k| {
        const br = self.buttonRect(k);
        const hovered = if (self.hover) |hv| hv == k else false;
        if (hovered) fill(mem, br, palette.hover);
        const color = if (hovered) palette.text else palette.text_inactive;
        drawIcon(mem, br, k, color, scale(8, dpi));
    }

    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn fill(hdc: c.HDC, rect: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

fn drawBorder(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer if (old) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.MoveToEx(hdc, r.left, r.top, null);
    _ = c.LineTo(hdc, r.right - 1, r.top);
    _ = c.LineTo(hdc, r.right - 1, r.bottom - 1);
    _ = c.LineTo(hdc, r.left, r.bottom - 1);
    _ = c.LineTo(hdc, r.left, r.top);
}

fn drawIcon(hdc: c.HDC, r: c.RECT, kind: Hit, color: c.COLORREF, size: i32) void {
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer if (old) |o| {
        _ = c.SelectObject(hdc, o);
    };
    const cx = @divTrunc(r.left + r.right, 2);
    const cy = @divTrunc(r.top + r.bottom, 2);
    const half = @divTrunc(size, 2);
    switch (kind) {
        .prev => {
            _ = c.MoveToEx(hdc, cx - half, cy + @divTrunc(half, 2), null);
            _ = c.LineTo(hdc, cx, cy - @divTrunc(half, 2));
            _ = c.LineTo(hdc, cx + half + 1, cy + @divTrunc(half, 2) + 1);
        },
        .next => {
            _ = c.MoveToEx(hdc, cx - half, cy - @divTrunc(half, 2), null);
            _ = c.LineTo(hdc, cx, cy + @divTrunc(half, 2));
            _ = c.LineTo(hdc, cx + half + 1, cy - @divTrunc(half, 2) - 1);
        },
        .close => {
            _ = c.MoveToEx(hdc, cx - half, cy - half, null);
            _ = c.LineTo(hdc, cx + half + 1, cy + half + 1);
            _ = c.MoveToEx(hdc, cx + half, cy - half, null);
            _ = c.LineTo(hdc, cx - half - 1, cy + half + 1);
        },
    }
}

fn editSubclassProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SearchOverlay = @ptrFromInt(ptr);
    const orig = self.orig_edit_proc orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_KEYDOWN => {
            if (wparam == c.VK_RETURN) {
                const shift = c.GetKeyState(c.VK_SHIFT) < 0;
                self.navigate(!shift);
                return 0;
            }
            if (wparam == c.VK_ESCAPE) {
                self.stopSearch();
                return 0;
            }
        },
        c.WM_CHAR => {
            if (wparam == c.VK_RETURN or wparam == c.VK_ESCAPE) return 0;
        },
        else => {},
    }
    return c.CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *SearchOverlay = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SearchOverlay = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_CTLCOLOREDIT => {
            const hdc: c.HDC = @ptrFromInt(wparam);
            const s = self.surface();
            const palette = TabBar.Palette.init(&s.app.config);
            _ = c.SetTextColor(hdc, palette.text);
            _ = c.SetBkColor(hdc, palette.active);
            if (self.edit_brush) |b| _ = c.DeleteObject(b);
            self.edit_brush = c.CreateSolidBrush(palette.active);
            return @bitCast(@intFromPtr(self.edit_brush));
        },

        c.WM_COMMAND => {
            const code: u16 = @truncate(wparam >> 16);
            const id: u16 = @truncate(wparam & 0xFFFF);
            if (id == edit_id and code == c.EN_CHANGE and !self.suppress_change) {
                self.notifyCurrentText();
                return 0;
            }
        },

        c.WM_MOUSEMOVE => {
            const x: i16 = @bitCast(c.loword(lparam));
            const y: i16 = @bitCast(c.hiword(lparam));
            if (self.dragging) {
                var pt: c.POINT = .{ .x = x, .y = y };
                _ = c.ClientToScreen(hwnd, &pt);
                const s = self.surface();
                if (s.hwnd) |shwnd| {
                    _ = c.ScreenToClient(shwnd, &pt);
                    const next = Corner.nearest(pt.x, pt.y, @intCast(s.size.width), @intCast(s.size.height));
                    if (next != self.corner) {
                        self.corner = next;
                        self.layout();
                    }
                }
                return 0;
            }
            if (!self.tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme).toBool()) self.tracking = true;
            }
            const next = self.hitAt(x, y);
            if (self.hover != next) {
                self.hover = next;
                self.invalidate();
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hover != null) {
                self.hover = null;
                self.invalidate();
            }
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            const x: i16 = @bitCast(c.loword(lparam));
            const y: i16 = @bitCast(c.hiword(lparam));
            if (self.hitAt(x, y)) |hit| {
                switch (hit) {
                    .prev => self.navigate(false),
                    .next => self.navigate(true),
                    .close => self.stopSearch(),
                }
                return 0;
            }
            self.dragging = true;
            self.drag_offset = .{ .x = x, .y = y };
            _ = c.SetCapture(hwnd);
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (self.dragging) {
                self.dragging = false;
                if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            self.dragging = false;
            return 0;
        },

        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (self.font) |f| _ = c.DeleteObject(f);
            if (self.edit_brush) |b| _ = c.DeleteObject(b);
            self.font = null;
            self.edit_brush = null;
            self.hwnd = null;
            self.edit_hwnd = null;
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "SearchOverlay Corner.nearest" {
    const testing = std.testing;
    try testing.expectEqual(Corner.top_left, Corner.nearest(50, 50, 800, 600));
    try testing.expectEqual(Corner.top_right, Corner.nearest(700, 50, 800, 600));
    try testing.expectEqual(Corner.bottom_left, Corner.nearest(50, 500, 800, 600));
    try testing.expectEqual(Corner.bottom_right, Corner.nearest(700, 500, 800, 600));
}

test "SearchOverlay formatCount" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", formatCount(&buf, null, null));
    try testing.expectEqualStrings("0/0", formatCount(&buf, null, 0));
    try testing.expectEqualStrings("?/5", formatCount(&buf, null, 5));
    try testing.expectEqualStrings("2/5", formatCount(&buf, 2, 5));
}
