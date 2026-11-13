const SurfaceOverlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const SplitView = @import("SplitView.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const banner_class_name = L("GhosttyChildBanner");
pub const pill_class_name = L("GhosttyStatusPill");
pub const scrollbar_class_name = L("GhosttyScrollbar");
pub const dim_class_name = L("GhosttySplitDim");

const banner_height = 34;
const banner_btn_w = 64;
const banner_btn_h = 22;
const pill_height = 24;
const pill_margin = 8;
const scrollbar_width = 8;
const min_thumb_height = 24;
const scrollbar_hide_timer_id: c.UINT_PTR = 1;
const scrollbar_hide_delay_ms: c.UINT = 1500;

banner_hwnd: ?c.HWND = null,
pill_hwnd: ?c.HWND = null,
scrollbar_hwnd: ?c.HWND = null,
dim_hwnd: ?c.HWND = null,
unfocused_split: bool = false,
font: ?c.HFONT = null,

child_exited: ?apprt.surface.Message.ChildExited = null,
banner_hover_close: bool = false,
banner_tracking: bool = false,

readonly: bool = false,
renderer_health: renderer.Health = .healthy,
key_sequence: std.ArrayList([:0]const u8) = .empty,
key_tables: std.ArrayList([:0]const u8) = .empty,
pill_text: [512]u8 = undefined,
pill_len: usize = 0,

scrollbar: terminal.Scrollbar = .{ .total = 0, .offset = 0, .len = 0 },
scrollbar_dragging: bool = false,
scrollbar_drag_grab: i32 = 0,
scrollbar_hover: bool = false,
scrollbar_tracking: bool = false,

pub const ThumbRange = struct {
    top: i32,
    bottom: i32,
};

fn surface(self: *SurfaceOverlay) *Surface {
    return @alignCast(@fieldParentPtr("overlay", self));
}

fn scale(v: i32, dpi: c.UINT) i32 {
    return @intCast(@divTrunc(v * @as(i32, @intCast(dpi)), 96));
}

pub fn create(self: *SurfaceOverlay, parent: c.HWND, instance: ?c.HINSTANCE) !void {
    self.banner_hwnd = c.CreateWindowExW(
        0,
        banner_class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;

    self.pill_hwnd = c.CreateWindowExW(
        c.WS_EX_TRANSPARENT,
        pill_class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;

    self.scrollbar_hwnd = c.CreateWindowExW(
        0,
        scrollbar_class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;

    self.dim_hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | @as(c.DWORD, @truncate(c.WS_EX_TRANSPARENT)),
        dim_class_name,
        null,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        0,
        0,
        parent,
        null,
        instance,
        self,
    ) orelse return error.CreateWindowFailed;

    self.updateFont();
}

pub fn deinit(self: *SurfaceOverlay, alloc: Allocator) void {
    for (self.key_sequence.items) |s| alloc.free(s);
    self.key_sequence.deinit(alloc);
    for (self.key_tables.items) |s| alloc.free(s);
    self.key_tables.deinit(alloc);
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
}

pub fn updateFont(self: *SurfaceOverlay) void {
    const hwnd = self.banner_hwnd orelse return;
    var ncm: c.NONCLIENTMETRICSW = .{};
    const dpi = c.GetDpiForWindow(hwnd);
    if (!c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi).toBool()) return;
    const font = c.CreateFontIndirectW(&ncm.lfMessageFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    self.layout();
}

pub fn topBannerHeight(self: *const SurfaceOverlay, dpi: c.UINT) i32 {
    if (self.child_exited == null) return 0;
    return scale(banner_height, dpi);
}

pub fn setChildExited(self: *SurfaceOverlay, data: apprt.surface.Message.ChildExited) bool {
    self.child_exited = data;
    self.layout();
    self.surface().search_overlay.layout();
    if (self.banner_hwnd) |hwnd| {
        _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
        _ = c.InvalidateRect(hwnd, null, .FALSE);
    }
    return true;
}

pub fn setReadonly(self: *SurfaceOverlay, v: bool) void {
    if (self.readonly == v) return;
    self.readonly = v;
    self.refreshPill();
}

pub fn setRendererHealth(self: *SurfaceOverlay, health: renderer.Health) void {
    if (self.renderer_health == health) return;
    self.renderer_health = health;
    self.refreshPill();
}

pub fn setKeySequence(self: *SurfaceOverlay, alloc: Allocator, value: apprt.action.KeySequence) !void {
    switch (value) {
        .trigger => |t| {
            var buf: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{f}", .{t});
            const copy = try alloc.dupeSentinel(u8, s, 0);
            errdefer alloc.free(copy);
            try self.key_sequence.append(alloc, copy);
        },
        .end => {
            for (self.key_sequence.items) |s| alloc.free(s);
            self.key_sequence.clearRetainingCapacity();
        },
    }
    self.refreshPill();
}

pub fn setKeyTable(self: *SurfaceOverlay, alloc: Allocator, value: apprt.action.KeyTable) !void {
    switch (value) {
        .activate => |name| {
            const copy = try alloc.dupeSentinel(u8, name, 0);
            errdefer alloc.free(copy);
            try self.key_tables.append(alloc, copy);
        },
        .deactivate => {
            if (self.key_tables.pop()) |s| alloc.free(s);
        },
        .deactivate_all => {
            for (self.key_tables.items) |s| alloc.free(s);
            self.key_tables.clearRetainingCapacity();
        },
    }
    self.refreshPill();
}

pub fn setScrollbar(self: *SurfaceOverlay, sb: terminal.Scrollbar) void {
    const changed = self.scrollbar.total != sb.total or
        self.scrollbar.offset != sb.offset or
        self.scrollbar.len != sb.len;
    self.scrollbar = sb;
    const s = self.surface();
    const hwnd = self.scrollbar_hwnd orelse return;
    if (s.app.config.scrollbar == .never or sb.total <= sb.len) {
        _ = c.KillTimer(hwnd, scrollbar_hide_timer_id);
        if (c.IsWindowVisible(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return;
    }
    if (changed) {
        self.layoutScrollbar();
        _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
        _ = c.InvalidateRect(hwnd, null, .FALSE);
        if (!self.scrollbar_dragging and !self.scrollbar_hover) {
            _ = c.SetTimer(hwnd, scrollbar_hide_timer_id, scrollbar_hide_delay_ms, null);
        }
    }
}

pub fn refreshPill(self: *SurfaceOverlay) void {
    const s = self.surface();
    const text = formatPillText(
        &self.pill_text,
        self.readonly,
        self.renderer_health,
        self.key_tables.items,
        self.key_sequence.items,
        s.hover_url,
    );
    self.pill_len = text.len;
    const hwnd = self.pill_hwnd orelse return;
    if (text.len == 0) {
        if (c.IsWindowVisible(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return;
    }
    self.layoutPill();
    if (!c.IsWindowVisible(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn formatPillText(
    buf: []u8,
    readonly: bool,
    health: renderer.Health,
    tables: []const [:0]const u8,
    seq: []const [:0]const u8,
    hover_url: ?[:0]const u8,
) []const u8 {
    var pos: usize = 0;
    const appendPart = struct {
        fn call(b: []u8, p: *usize, part: []const u8) void {
            if (part.len == 0) return;
            if (p.* > 0 and p.* + 3 < b.len) {
                @memcpy(b[p.*..][0..3], " | ");
                p.* += 3;
            }
            const n = @min(part.len, b.len - p.*);
            @memcpy(b[p.*..][0..n], part[0..n]);
            p.* += n;
        }
    }.call;

    if (readonly) appendPart(buf, &pos, "Read-Only");
    if (health != .healthy) appendPart(buf, &pos, "Shader Error");
    if (tables.len > 0) {
        var tmp: [128]u8 = undefined;
        if (std.fmt.bufPrint(&tmp, "Key Table: {s}", .{tables[tables.len - 1]})) |part| {
            appendPart(buf, &pos, part);
        } else |_| {}
    }
    if (seq.len > 0) {
        var tmp: [128]u8 = undefined;
        var tpos: usize = 0;
        const prefix = "Key Seq: ";
        @memcpy(tmp[0..prefix.len], prefix);
        tpos = prefix.len;
        for (seq, 0..) |item, i| {
            if (i > 0 and tpos + 1 < tmp.len) {
                tmp[tpos] = ' ';
                tpos += 1;
            }
            const n = @min(item.len, tmp.len - tpos);
            @memcpy(tmp[tpos..][0..n], item[0..n]);
            tpos += n;
        }
        appendPart(buf, &pos, tmp[0..tpos]);
    }
    if (hover_url) |url| {
        if (url.len > 0) appendPart(buf, &pos, url);
    }
    return buf[0..pos];
}

pub fn layout(self: *SurfaceOverlay) void {
    const s = self.surface();
    const w: i32 = @intCast(s.size.width);

    if (self.banner_hwnd) |hwnd| {
        const dpi = c.GetDpiForWindow(hwnd);
        const bh = self.topBannerHeight(dpi);
        if (bh > 0) {
            _ = c.SetWindowPos(hwnd, null, 0, 0, w, bh, c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
            _ = c.InvalidateRect(hwnd, null, .FALSE);
        } else if (c.IsWindowVisible(hwnd).toBool()) {
            _ = c.ShowWindow(hwnd, c.SW_HIDE);
        }
    }
    self.layoutPill();
    self.layoutScrollbar();
    self.layoutDim();
}

pub fn setUnfocusedSplit(self: *SurfaceOverlay, unfocused: bool) void {
    if (self.unfocused_split == unfocused) return;
    self.unfocused_split = unfocused;
    self.layoutDim();
}

pub fn layoutDim(self: *SurfaceOverlay) void {
    const hwnd = self.dim_hwnd orelse return;
    const s = self.surface();
    const alpha = SplitView.unfocusedAlpha(s.app.config.@"unfocused-split-opacity");
    const should_show = self.unfocused_split and alpha > 0 and !s.search_overlay.active;
    if (!should_show) {
        if (c.IsWindowVisible(hwnd).toBool()) _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return;
    }
    _ = c.SetLayeredWindowAttributes(hwnd, 0, alpha, c.LWA_ALPHA);
    const w: i32 = @intCast(s.size.width);
    const h: i32 = @intCast(s.size.height);
    _ = c.SetWindowPos(hwnd, null, 0, 0, w, h, c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
    _ = c.InvalidateRect(hwnd, null, .FALSE);
}

fn layoutPill(self: *SurfaceOverlay) void {
    const hwnd = self.pill_hwnd orelse return;
    if (self.pill_len == 0) return;
    const s = self.surface();
    const dpi = c.GetDpiForWindow(hwnd);
    const parent_w: i32 = @intCast(s.size.width);
    const parent_h: i32 = @intCast(s.size.height);
    const m = scale(pill_margin, dpi);
    const h = scale(pill_height, dpi);
    const char_w = @max(6, scale(7, dpi));
    const desired_w = @as(i32, @intCast(self.pill_len)) * char_w + scale(20, dpi);
    const w = std.math.clamp(desired_w, scale(64, dpi), @max(scale(64, dpi), parent_w - m * 2));
    const top = @max(m, parent_h - h - m);
    const cursor_in_left = s.cursor_pos.x >= 0 and s.cursor_pos.x < @as(f64, @floatFromInt(w + m * 2)) and
        s.cursor_pos.y >= @as(f64, @floatFromInt(top - m));
    const left = if (cursor_in_left) @max(m, parent_w - w - m) else m;
    _ = c.SetWindowPos(hwnd, null, left, top, w, h, c.SWP_NOACTIVATE | c.SWP_NOZORDER);
}

fn layoutScrollbar(self: *SurfaceOverlay) void {
    const hwnd = self.scrollbar_hwnd orelse return;
    const s = self.surface();
    if (s.app.config.scrollbar == .never or self.scrollbar.total <= self.scrollbar.len) return;
    const dpi = c.GetDpiForWindow(hwnd);
    const sw = scale(scrollbar_width, dpi);
    const top_inset = self.topBannerHeight(dpi);
    const w: i32 = @intCast(s.size.width);
    const h: i32 = @intCast(s.size.height);
    _ = c.SetWindowPos(
        hwnd,
        null,
        @max(0, w - sw),
        top_inset,
        sw,
        @max(0, h - top_inset),
        c.SWP_NOACTIVATE | c.SWP_NOZORDER,
    );
}

pub fn thumbRange(track_h: i32, min_thumb: i32, sb: terminal.Scrollbar) ThumbRange {
    if (track_h <= 0 or sb.total == 0 or sb.total <= sb.len) {
        return .{ .top = 0, .bottom = @max(0, track_h) };
    }
    const total_f: f64 = @floatFromInt(sb.total);
    const len_f: f64 = @floatFromInt(sb.len);
    const track_f: f64 = @floatFromInt(track_h);
    const raw_h: i32 = @intFromFloat(@round((len_f / total_f) * track_f));
    const thumb_h = std.math.clamp(raw_h, @min(min_thumb, track_h), track_h);
    const max_offset = sb.total - sb.len;
    const avail = track_h - thumb_h;
    const top: i32 = if (max_offset == 0 or avail <= 0)
        0
    else
        @intFromFloat(@round((@as(f64, @floatFromInt(@min(sb.offset, max_offset))) / @as(f64, @floatFromInt(max_offset))) * @as(f64, @floatFromInt(avail))));
    return .{ .top = top, .bottom = top + thumb_h };
}

pub fn rowFromThumbTop(track_h: i32, thumb_h: i32, top: i32, sb: terminal.Scrollbar) usize {
    if (sb.total <= sb.len) return 0;
    const max_offset = sb.total - sb.len;
    const avail = track_h - thumb_h;
    if (avail <= 0) return 0;
    const clamped = std.math.clamp(top, 0, avail);
    const ratio = @as(f64, @floatFromInt(clamped)) / @as(f64, @floatFromInt(avail));
    return @intFromFloat(@round(ratio * @as(f64, @floatFromInt(max_offset))));
}

fn closeButtonRect(hwnd: c.HWND) c.RECT {
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const dpi = c.GetDpiForWindow(hwnd);
    const bw = scale(banner_btn_w, dpi);
    const bh = scale(banner_btn_h, dpi);
    const right = r.right - scale(10, dpi);
    const top = @divTrunc((r.bottom - r.top) - bh, 2);
    return .{ .left = right - bw, .top = top, .right = right, .bottom = top + bh };
}

fn paintBanner(self: *SurfaceOverlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    const exited = self.child_exited orelse return;
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

    const bg: c.COLORREF = if (exited.exit_code == 0) 0x00284820 else 0x00242458;
    const border: c.COLORREF = if (exited.exit_code == 0) 0x00488838 else 0x004040A8;
    const text_color: c.COLORREF = 0x00F0F0F0;

    fill(mem, rect, bg);
    fill(mem, .{ .left = 0, .top = h - 1, .right = w, .bottom = h }, border);

    _ = c.SetBkMode(mem, c.TRANSPARENT);
    _ = c.SetTextColor(mem, text_color);

    const btn = closeButtonRect(hwnd);
    const dpi = c.GetDpiForWindow(hwnd);
    var msg_buf: [160]u8 = undefined;
    const msg_utf8 = std.fmt.bufPrint(
        &msg_buf,
        "Process exited with code {d} ({d}ms)",
        .{ exited.exit_code, exited.runtime_ms },
    ) catch "Process exited";
    var wide_buf: [160]u16 = undefined;
    if (std.unicode.utf8ToUtf16Le(&wide_buf, msg_utf8)) |n| {
        var text_r: c.RECT = .{
            .left = scale(12, dpi),
            .top = 0,
            .right = btn.left - scale(8, dpi),
            .bottom = h,
        };
        _ = c.DrawTextW(
            mem,
            &wide_buf,
            @intCast(n),
            &text_r,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    } else |_| {}

    fill(mem, btn, if (self.banner_hover_close) border else bg);
    drawRectBorder(mem, btn, border);
    var btn_r = btn;
    const close_w = L("Close");
    _ = c.DrawTextW(
        mem,
        close_w.ptr,
        @intCast(close_w.len),
        &btn_r,
        c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX,
    );

    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn paintPill(self: *SurfaceOverlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0 or self.pill_len == 0) return;

    const s = self.surface();
    const palette = TabBar.Palette.init(&s.app.config);
    const dpi = c.GetDpiForWindow(hwnd);

    fill(hdc, rect, palette.bar);
    drawRectBorder(hdc, rect, palette.separator);

    const old_font = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old_font) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, palette.text);

    var wide_buf: [512]u16 = undefined;
    if (std.unicode.utf8ToUtf16Le(&wide_buf, self.pill_text[0..self.pill_len])) |n| {
        var tr: c.RECT = .{
            .left = scale(8, dpi),
            .top = 0,
            .right = w - scale(8, dpi),
            .bottom = h,
        };
        _ = c.DrawTextW(
            hdc,
            &wide_buf,
            @intCast(n),
            &tr,
            c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    } else |_| {}
}

fn paintScrollbar(self: *SurfaceOverlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;

    const s = self.surface();
    const palette = TabBar.Palette.init(&s.app.config);
    const dpi = c.GetDpiForWindow(hwnd);
    fill(hdc, rect, palette.active);

    const range = thumbRange(h, scale(min_thumb_height, dpi), self.scrollbar);
    const thumb_color = if (self.scrollbar_dragging or self.scrollbar_hover)
        palette.text_inactive
    else
        palette.separator;
    const inset = @max(1, scale(1, dpi));
    fill(hdc, .{
        .left = inset,
        .top = range.top,
        .right = @max(inset + 1, w - inset),
        .bottom = range.bottom,
    }, thumb_color);
}

fn fill(hdc: c.HDC, rect: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &rect, brush);
}

fn drawRectBorder(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
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

pub fn bannerWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *SurfaceOverlay = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.banner_hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SurfaceOverlay = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            self.paintBanner(hwnd);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_MOUSEMOVE => {
            if (!self.banner_tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme).toBool()) self.banner_tracking = true;
            }
            const x: i16 = @bitCast(c.loword(lparam));
            const y: i16 = @bitCast(c.hiword(lparam));
            const btn = closeButtonRect(hwnd);
            const over = x >= btn.left and x < btn.right and y >= btn.top and y < btn.bottom;
            if (over != self.banner_hover_close) {
                self.banner_hover_close = over;
                _ = c.InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        c.WM_MOUSELEAVE => {
            self.banner_tracking = false;
            if (self.banner_hover_close) {
                self.banner_hover_close = false;
                _ = c.InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        c.WM_LBUTTONUP => {
            const x: i16 = @bitCast(c.loword(lparam));
            const y: i16 = @bitCast(c.hiword(lparam));
            const btn = closeButtonRect(hwnd);
            if (x >= btn.left and x < btn.right and y >= btn.top and y < btn.bottom) {
                self.surface().close(false);
            }
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.banner_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn pillWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *SurfaceOverlay = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.pill_hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SurfaceOverlay = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            self.paintPill(hwnd);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.pill_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn dimWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *SurfaceOverlay = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.dim_hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SurfaceOverlay = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = .{};
            const hdc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            var r: c.RECT = .{};
            _ = c.GetClientRect(hwnd, &r);
            const s = self.surface();
            const cfg = &s.app.config;
            const col = cfg.@"unfocused-split-fill" orelse cfg.background;
            fill(hdc, r, Window.Chrome.colorRef(col));
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.dim_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

pub fn scrollbarWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *SurfaceOverlay = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.scrollbar_hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SurfaceOverlay = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            self.paintScrollbar(hwnd);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_TIMER => if (wparam == scrollbar_hide_timer_id) {
            _ = c.KillTimer(hwnd, scrollbar_hide_timer_id);
            if (!self.scrollbar_dragging and !self.scrollbar_hover) {
                _ = c.ShowWindow(hwnd, c.SW_HIDE);
            }
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (!self.scrollbar_tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme).toBool()) self.scrollbar_tracking = true;
            }
            if (!self.scrollbar_hover) {
                self.scrollbar_hover = true;
                _ = c.KillTimer(hwnd, scrollbar_hide_timer_id);
                _ = c.InvalidateRect(hwnd, null, .FALSE);
            }
            if (self.scrollbar_dragging) {
                const y: i16 = @bitCast(c.hiword(lparam));
                self.scrollToMouseY(hwnd, y - self.scrollbar_drag_grab);
            }
            return 0;
        },
        c.WM_MOUSELEAVE => {
            self.scrollbar_tracking = false;
            self.scrollbar_hover = false;
            if (!self.scrollbar_dragging) {
                _ = c.SetTimer(hwnd, scrollbar_hide_timer_id, scrollbar_hide_delay_ms, null);
            }
            _ = c.InvalidateRect(hwnd, null, .FALSE);
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            const y: i16 = @bitCast(c.hiword(lparam));
            var r: c.RECT = .{};
            _ = c.GetClientRect(hwnd, &r);
            const h = r.bottom - r.top;
            const dpi = c.GetDpiForWindow(hwnd);
            const range = thumbRange(h, scale(min_thumb_height, dpi), self.scrollbar);
            const thumb_h = range.bottom - range.top;
            self.scrollbar_dragging = true;
            if (y >= range.top and y < range.bottom) {
                self.scrollbar_drag_grab = y - range.top;
            } else {
                self.scrollbar_drag_grab = @divTrunc(thumb_h, 2);
                self.scrollToMouseY(hwnd, y - self.scrollbar_drag_grab);
            }
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, .FALSE);
            return 0;
        },
        c.WM_LBUTTONUP => {
            if (self.scrollbar_dragging) {
                self.scrollbar_dragging = false;
                if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
                _ = c.InvalidateRect(hwnd, null, .FALSE);
            }
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            self.scrollbar_dragging = false;
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.KillTimer(hwnd, scrollbar_hide_timer_id);
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.scrollbar_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn scrollToMouseY(self: *SurfaceOverlay, hwnd: c.HWND, target_top: i32) void {
    const s = self.surface();
    if (!s.initialized) return;
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const h = r.bottom - r.top;
    const dpi = c.GetDpiForWindow(hwnd);
    const range = thumbRange(h, scale(min_thumb_height, dpi), self.scrollbar);
    const row = rowFromThumbTop(h, range.bottom - range.top, target_top, self.scrollbar);
    _ = s.core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
        log.warn("error performing scroll_to_row err={}", .{err});
    };
}

test "SurfaceOverlay thumbRange and rowFromThumbTop" {
    const testing = std.testing;
    const sb: terminal.Scrollbar = .{ .total = 100, .offset = 25, .len = 20 };
    const r = thumbRange(200, 20, sb);
    try testing.expectEqual(@as(i32, 40), r.bottom - r.top);
    try testing.expectEqual(@as(i32, 50), r.top);
    const row = rowFromThumbTop(200, r.bottom - r.top, r.top, sb);
    try testing.expectEqual(@as(usize, 25), row);
}

test "SurfaceOverlay formatPillText" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const tables = [_][:0]const u8{"resize"};
    const s = formatPillText(&buf, true, .healthy, &tables, &.{}, "https://ghostty.org");
    try testing.expectEqualStrings("Read-Only | Key Table: resize | https://ghostty.org", s);
}
