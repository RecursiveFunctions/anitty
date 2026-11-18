const TabBar = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const dialogs = @import("dialogs.zig");
const i18n = @import("../../os/main.zig").i18n;

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const bar_height = 32;
const max_tab_width = 240;
const min_tab_width = 48;
const tab_padding = 10;
const close_size = 16;
const glyph_size = 8;
const edit_id: usize = 1;

const MenuCmd = enum(c.UINT_PTR) {
    rename_tab = 1,
    move_to_new_window = 2,
    close_tab = 3,
    close_other_tabs = 4,
    close_tabs_right = 5,
    new_tab = 6,
};

hwnd: ?c.HWND = null,
edit_hwnd: ?c.HWND = null,
tooltip_hwnd: ?c.HWND = null,
orig_edit_proc: ?c.WNDPROC = null,
edit_brush: ?c.HBRUSH = null,
renaming_surface: ?*Surface = null,
font: ?c.HFONT = null,
mem_dc: ?c.HDC = null,
mem_bmp: ?c.HBITMAP = null,
mem_old_bmp: ?c.HGDIOBJ = null,
mem_w: i32 = 0,
mem_h: i32 = 0,
hover: ?Hit = null,
tracking: bool = false,
drag: ?Drag = null,
drop_hint: ?usize = null,
overlay: bool = false,

const Drag = struct {
    surface: *Surface,
    origin: usize,
    count: usize,
    start_x: i32,
    start_y: i32,
    grab: i32,
    x: i32,
    moving: bool = false,
    took_focus: bool = false,
    float: ?Float = null,
};

const Float = struct {
    window: *Window,
    offset: c.POINT,
    home: c.RECT,
    target: ?*Window = null,
};

const Hit = union(enum) {
    tab: usize,
    close: usize,
    new,
};

pub const Palette = struct {
    bar: c.COLORREF,
    active: c.COLORREF,
    hover: c.COLORREF,
    text: c.COLORREF,
    text_inactive: c.COLORREF,
    separator: c.COLORREF,

    pub fn init(config: *const configpkg.Config) Palette {
        return initWithDynamic(config, null, null);
    }

    pub fn initWithDynamic(
        config: *const configpkg.Config,
        dynamic_bg: ?configpkg.Config.Color,
        dynamic_fg: ?configpkg.Config.Color,
    ) Palette {
        const bg = dynamic_bg orelse config.background;
        const fg = dynamic_fg orelse config.foreground;
        const dark = Window.Chrome.isDark(bg);
        const bar = mix(bg, if (dark) .{ .r = 0, .g = 0, .b = 0 } else fg, if (dark) 0.35 else 0.08);
        return .{
            .bar = Window.Chrome.colorRef(bar),
            .active = Window.Chrome.colorRef(bg),
            .hover = mixRef(bar, Window.Chrome.colorRef(bg), 0.5),
            .text = Window.Chrome.colorRef(fg),
            .text_inactive = Window.Chrome.colorRef(mix(fg, bg, 0.35)),
            .separator = Window.Chrome.colorRef(mix(bg, fg, 0.2)),
        };
    }

    fn mix(a: configpkg.Config.Color, b: configpkg.Config.Color, t: f32) configpkg.Config.Color {
        return .{ .r = lerp(a.r, b.r, t), .g = lerp(a.g, b.g, t), .b = lerp(a.b, b.b, t) };
    }

    fn mixRef(a: configpkg.Config.Color, b: c.COLORREF, t: f32) c.COLORREF {
        return Window.Chrome.colorRef(mix(a, .{
            .r = @truncate(b),
            .g = @truncate(b >> 8),
            .b = @truncate(b >> 16),
        }, t));
    }

    fn lerp(a: u8, b: u8, t: f32) u8 {
        const af: f32 = @floatFromInt(a);
        const bf: f32 = @floatFromInt(b);
        return @intFromFloat(@round(af + (bf - af) * t));
    }
};

pub fn create(self: *TabBar, parent: c.HWND, instance: ?c.HINSTANCE) !void {
    const hwnd = c.CreateWindowExW(
        0,
        App.tab_bar_class_name,
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
        c.WS_CHILD | c.ES_AUTOHSCROLL,
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

    if (c.CreateWindowExW(
        c.WS_EX_TOPMOST,
        L("tooltips_class32"),
        null,
        c.WS_POPUP | c.TTS_NOPREFIX | c.TTS_ALWAYSTIP,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        hwnd,
        null,
        instance,
        null,
    )) |tip| {
        self.tooltip_hwnd = tip;
        _ = c.SetWindowPos(tip, c.HWND_TOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
        var ti: c.TTTOOLINFOW = .{
            .uFlags = c.TTF_IDISHWND | c.TTF_SUBCLASS,
            .hwnd = hwnd,
            .uId = @intFromPtr(hwnd),
            .lpszText = L(""),
        };
        _ = c.SendMessageW(tip, c.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&ti)));
        _ = c.SendMessageW(tip, c.TTM_SETMAXTIPWIDTH, 0, 480);
    }

    self.updateFont();
}

fn window(self: *TabBar) *Window {
    return @fieldParentPtr("tab_bar", self);
}

pub fn height(self: *const TabBar) i32 {
    const hwnd = self.hwnd orelse return 0;
    return c.scaleDpi(bar_height, c.GetDpiForWindow(hwnd));
}

pub fn invalidate(self: *TabBar) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn updateFont(self: *TabBar) void {
    const hwnd = self.hwnd orelse return;
    var ncm: c.NONCLIENTMETRICSW = .{};
    const dpi = c.GetDpiForWindow(hwnd);
    if (!c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi).toBool()) {
        log.warn("unable to read non-client metrics for tab bar font", .{});
        return;
    }
    const font = c.CreateFontIndirectW(&ncm.lfCaptionFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;
    if (self.edit_hwnd) |edit| {
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    self.invalidate();
}

const Layout = struct {
    tab_width: i32,
    count: usize,
    height: i32,
    dpi: c.UINT,

    fn init(bar: *TabBar) ?Layout {
        const hwnd = bar.hwnd orelse return null;
        var rect: c.RECT = .{};
        _ = c.GetClientRect(hwnd, &rect);
        const dpi = c.GetDpiForWindow(hwnd);
        const h = rect.bottom - rect.top;
        const count = bar.window().tabs.items.len;
        const avail = @max(0, rect.right - rect.left - h);
        const n: i32 = @intCast(@max(count, 1));
        const w = std.math.clamp(@divTrunc(avail, n), c.scaleDpi(min_tab_width, dpi), c.scaleDpi(max_tab_width, dpi));
        return .{ .tab_width = w, .count = count, .height = h, .dpi = dpi };
    }

    fn tab(self: Layout, i: usize) c.RECT {
        const left = self.tab_width * @as(i32, @intCast(i));
        return .{ .left = left, .top = 0, .right = left + self.tab_width, .bottom = self.height };
    }

    fn close(self: Layout, i: usize) c.RECT {
        return self.closeIn(self.tab(i));
    }

    fn closeIn(self: Layout, t: c.RECT) c.RECT {
        const size = c.scaleDpi(close_size, self.dpi);
        const right = t.right - c.scaleDpi(tab_padding, self.dpi) + @divTrunc(size - c.scaleDpi(glyph_size, self.dpi), 2);
        const top = @divTrunc(self.height - size, 2);
        return .{ .left = right - size, .top = top, .right = right, .bottom = top + size };
    }

    fn new(self: Layout) c.RECT {
        const left = self.tab_width * @as(i32, @intCast(self.count));
        return .{ .left = left, .top = 0, .right = left + self.height, .bottom = self.height };
    }

    fn hit(self: Layout, x: i32, y: i32) ?Hit {
        if (c.rectContains(self.new(), x, y)) return .new;
        for (0..self.count) |i| {
            if (!c.rectContains(self.tab(i), x, y)) continue;
            if (c.rectContains(self.close(i), x, y)) return .{ .close = i };
            return .{ .tab = i };
        }
        return null;
    }
};

fn hitEql(a: ?Hit, b: ?Hit) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.meta.eql(x, y);
}

fn paint(self: *TabBar, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;

    if (self.mem_dc == null or self.mem_bmp == null or self.mem_w != w or self.mem_h != h) {
        self.releaseBackbuffer();
        const mem = c.CreateCompatibleDC(hdc) orelse return;
        const bmp = c.CreateCompatibleBitmap(hdc, w, h) orelse {
            _ = c.DeleteDC(mem);
            return;
        };
        self.mem_old_bmp = c.SelectObject(mem, bmp);
        self.mem_dc = mem;
        self.mem_bmp = bmp;
        self.mem_w = w;
        self.mem_h = h;
    }
    const mem = self.mem_dc.?;
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |o| {
        _ = c.SelectObject(mem, o);
    };

    self.draw(mem, rect);
    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn releaseBackbuffer(self: *TabBar) void {
    if (self.mem_dc) |mem| {
        if (self.mem_old_bmp) |old| _ = c.SelectObject(mem, old);
        _ = c.DeleteDC(mem);
    }
    if (self.mem_bmp) |bmp| _ = c.DeleteObject(bmp);
    self.mem_dc = null;
    self.mem_bmp = null;
    self.mem_old_bmp = null;
    self.mem_w = 0;
    self.mem_h = 0;
}

fn draw(self: *TabBar, hdc: c.HDC, rect: c.RECT) void {
    const win = self.window();
    const palette = win.palette();
    const layout = Layout.init(self) orelse return;

    c.fillRectColor(hdc, rect, palette.bar);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    const dragged = self.draggedIndex();
    for (0..layout.count) |i| {
        if (dragged) |d| if (d == i) continue;
        self.drawTab(hdc, palette, layout, i, layout.tab(i));
    }

    const new = layout.new();
    const new_hovered = if (self.hover) |hv| hv == .new else false;
    if (new_hovered) c.fillRectColor(hdc, new, palette.hover);
    c.drawCrossGlyph(hdc, new, if (new_hovered) palette.text else palette.text_inactive, c.scaleDpi(10, layout.dpi), true);

    if (self.drop_hint) |i| {
        const x = std.math.clamp(layout.tab_width * @as(i32, @intCast(i)), 1, @max(1, rect.right - 2));
        const half = @max(1, c.scaleDpi(1, layout.dpi));
        const inset = @divTrunc(layout.height, 6);
        c.fillRectColor(hdc, .{ .left = x - half, .top = inset, .right = x + half, .bottom = layout.height - inset }, palette.text);
    }

    if (dragged) |i| {
        const d = self.drag.?;
        const left = dragLeft(layout, d.x - d.grab);
        self.drawTab(hdc, palette, layout, i, .{
            .left = left,
            .top = 0,
            .right = left + layout.tab_width,
            .bottom = layout.height,
        });
    }
}

fn drawTab(self: *TabBar, hdc: c.HDC, palette: Palette, layout: Layout, i: usize, r: c.RECT) void {
    const win = self.window();
    const active = i == win.active;
    const hovered = if (self.hover) |hv| switch (hv) {
        .tab, .close => |idx| idx == i,
        .new => false,
    } else false;
    if (active) {
        c.fillRectColor(hdc, r, palette.active);
    } else if (hovered) {
        c.fillRectColor(hdc, r, palette.hover);
    }
    if (!active and i + 1 != win.active) {
        const inset = @divTrunc(layout.height, 4);
        c.drawLine(hdc, palette.separator, 1, r.right - 1, r.top + inset, r.right - 1, r.bottom - inset);
    }

    const close = layout.closeIn(r);
    var text_rect: c.RECT = .{
        .left = r.left + c.scaleDpi(tab_padding, layout.dpi),
        .top = r.top,
        .right = close.left - c.scaleDpi(4, layout.dpi),
        .bottom = r.bottom,
    };
    _ = c.SetTextColor(hdc, if (active) palette.text else palette.text_inactive);
    const raw_title = win.tabTitle(i);
    var wide_buf: [512]u16 = undefined;
    var wide_len: usize = 0;
    if (win.app.config.@"bell-features".title and win.tabHasBell(i)) {
        const bell_prefix = L("\u{1F514} ");
        @memcpy(wide_buf[0..bell_prefix.len], bell_prefix);
        wide_len = bell_prefix.len;
    }
    const max_utf8 = @min(raw_title.len, wide_buf.len - wide_len);
    var title_end = max_utf8;
    if (title_end < raw_title.len) {
        while (title_end > 0 and (raw_title[title_end] & 0xC0) == 0x80) : (title_end -= 1) {}
    }
    if (std.unicode.utf8ToUtf16Le(wide_buf[wide_len..], raw_title[0..title_end])) |n| {
        wide_len += n;
        if (wide_len > 0) {
            _ = c.DrawTextW(
                hdc,
                &wide_buf,
                @intCast(wide_len),
                &text_rect,
                c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
            );
        }
    } else |_| {}

    if (active or hovered) {
        const close_hovered = if (self.hover) |hv| switch (hv) {
            .close => |idx| idx == i,
            else => false,
        } else false;
        if (close_hovered) c.fillRectColor(hdc, close, palette.separator);
        const color = if (active or close_hovered) palette.text else palette.text_inactive;
        c.drawCrossGlyph(hdc, close, color, c.scaleDpi(glyph_size, layout.dpi), false);
    }
}

fn setHover(self: *TabBar, hit: ?Hit) void {
    if (hitEql(self.hover, hit)) return;
    self.hover = hit;
    self.updateTooltip(hit);
    self.invalidate();
}

fn updateTooltip(self: *TabBar, hit: ?Hit) void {
    const tip = self.tooltip_hwnd orelse return;
    const hwnd = self.hwnd orelse return;
    const win = self.window();
    const alloc = win.app.core_app.alloc;

    var ti: c.TTTOOLINFOW = .{
        .uFlags = c.TTF_IDISHWND | c.TTF_SUBCLASS,
        .hwnd = hwnd,
        .uId = @intFromPtr(hwnd),
        .lpszText = L(""),
    };

    const idx: usize = if (hit) |h| switch (h) {
        .tab, .close => |i| i,
        .new => {
            ti.lpszText = L("New Tab");
            _ = c.SendMessageW(tip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
            return;
        },
    } else {
        _ = c.SendMessageW(tip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        return;
    };

    if (idx >= win.tabs.items.len) {
        _ = c.SendMessageW(tip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        return;
    }

    const title = win.tabTitle(idx);
    const pwd = win.tabs.items[idx].focused.getPwd();
    const combined = if (pwd) |p| (if (p.len > 0 and !std.mem.eql(u8, p, title))
        std.fmt.allocPrint(alloc, "{s}\r\n{s}", .{ title, p }) catch null
    else
        null) else null;
    defer if (combined) |s| alloc.free(s);

    const text = combined orelse title;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch {
        _ = c.SendMessageW(tip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
        return;
    };
    defer alloc.free(wide);
    ti.lpszText = wide.ptr;
    _ = c.SendMessageW(tip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&ti)));
}

fn hitAt(self: *TabBar, lparam: c.LPARAM) ?Hit {
    const layout = Layout.init(self) orelse return null;
    return layout.hit(c.xFromLparam(lparam), c.yFromLparam(lparam));
}

fn dragLeft(layout: Layout, left: i32) i32 {
    const n: i32 = @intCast(@max(layout.count, 1) - 1);
    return std.math.clamp(left, 0, layout.tab_width * n);
}

fn dragIndex(self: *TabBar, d: Drag) ?usize {
    const win = self.window();
    if (win.tabs.items.len != d.count) return null;
    return win.tabIndex(d.surface);
}

fn draggedIndex(self: *TabBar) ?usize {
    const d = self.drag orelse return null;
    if (!d.moving) return null;
    return self.dragIndex(d);
}

fn beginDrag(self: *TabBar, hwnd: c.HWND, index: usize, x: i32, y: i32) void {
    self.cancelRename(false);
    const win = self.window();
    const layout = Layout.init(self) orelse return;
    if (index >= layout.count) return;
    self.drag = .{
        .surface = win.tabs.items[index].focused,
        .origin = index,
        .count = layout.count,
        .start_x = x,
        .start_y = y,
        .grab = x - layout.tab(index).left,
        .x = x,
    };
    _ = c.SetCapture(hwnd);
}

fn dragTo(self: *TabBar, hwnd: c.HWND, lparam: c.LPARAM) void {
    const d = &(self.drag orelse return);
    const x = c.xFromLparam(lparam);
    const y = c.yFromLparam(lparam);
    var pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &pt);
    if (d.float != null) return self.floatTo(pt);
    const index = self.dragIndex(d.*) orelse return self.endDrag(false);
    const layout = Layout.init(self) orelse return;
    d.x = x;
    if (!d.moving) {
        if (@abs(x - d.start_x) < c.GetSystemMetrics(c.SM_CXDRAG) and
            @abs(y - d.start_y) < c.GetSystemMetrics(c.SM_CYDRAG)) return;
        d.moving = true;
        self.hover = null;
        if (c.GetFocus() != null) {
            _ = c.SetFocus(self.hwnd);
            d.took_focus = true;
        }
    }
    if (self.leftBar(hwnd, pt)) return self.detach(index, pt);
    const left = dragLeft(layout, x - d.grab);
    const w = @max(layout.tab_width, 1);
    const target: usize = @intCast(@divTrunc(left + @divTrunc(w, 2), w));
    if (target != index) {
        const delta = @as(isize, @intCast(target)) - @as(isize, @intCast(index));
        _ = self.window().moveTab(d.surface, delta);
    }
    self.invalidate();
}

fn leftBar(self: *TabBar, hwnd: c.HWND, pt: c.POINT) bool {
    const win_hwnd = self.window().hwnd orelse return false;
    var bar: c.RECT = .{};
    var win: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &bar);
    _ = c.GetWindowRect(win_hwnd, &win);
    if (pt.x < win.left or pt.x >= win.right) return true;
    const h = bar.bottom - bar.top;
    return pt.y < bar.top - h or pt.y >= bar.bottom + h;
}

fn detach(self: *TabBar, index: usize, pt: c.POINT) void {
    const d = &(self.drag orelse return);
    const win = self.window();
    const win_hwnd = win.hwnd orelse return;
    var home: c.RECT = .{};
    _ = c.GetWindowRect(win_hwnd, &home);
    const float = if (win.tabs.items.len == 1)
        win
    else
        win.detachTab(index, pt, d.grab) orelse return self.endDrag(false);
    const float_hwnd = float.hwnd orelse return self.endDrag(false);
    var rect: c.RECT = .{};
    _ = c.GetWindowRect(float_hwnd, &rect);
    d.float = .{
        .window = float,
        .offset = .{ .x = pt.x - rect.left, .y = pt.y - rect.top },
        .home = home,
    };
    if (d.took_focus) _ = c.SetFocus(self.hwnd);
    self.invalidate();
}

fn alive(app: *App, win: *Window) bool {
    for (app.windows.items) |w| if (w == win) return win.hwnd != null;
    return false;
}

fn floatTo(self: *TabBar, pt: c.POINT) void {
    const d = &(self.drag orelse return);
    const f = &(d.float orelse return);
    const app = self.window().app;
    if (!alive(app, f.window)) return self.endDrag(false);
    const float_hwnd = f.window.hwnd.?;
    _ = c.SetWindowPos(
        float_hwnd,
        null,
        pt.x - f.offset.x,
        pt.y - f.offset.y,
        0,
        0,
        c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOREDRAW | c.SWP_NOCOPYBITS | c.SWP_NOSENDCHANGING,
    );
    const target = windowUnder(app, pt, float_hwnd);
    const at = if (target) |t| t.tab_bar.dropIndex(pt) else null;
    const next = if (at != null) target else null;
    if (f.target) |old| if (old != next and alive(app, old)) old.tab_bar.setDropHint(null);
    f.target = next;
    if (next) |t| t.tab_bar.setDropHint(at);
}

fn windowUnder(app: *App, pt: c.POINT, skip: c.HWND) ?*Window {
    var next = c.GetTopWindow(null);
    while (next) |h| : (next = c.GetWindow(h, c.GW_HWNDNEXT)) {
        if (h == skip) continue;
        if (!c.IsWindowVisible(h).toBool() or c.IsIconic(h).toBool()) continue;
        const ex: usize = @bitCast(c.GetWindowLongPtrW(h, c.GWL_EXSTYLE));
        if (ex & c.WS_EX_TRANSPARENT != 0) continue;
        var cloaked: c.DWORD = 0;
        if (c.DwmGetWindowAttribute(h, c.DWMWA_CLOAKED, &cloaked, @sizeOf(c.DWORD)) == 0 and cloaked != 0) continue;
        var r: c.RECT = .{};
        if (!c.GetWindowRect(h, &r).toBool() or !c.rectContains(r, pt.x, pt.y)) continue;
        for (app.windows.items) |w| if (w.hwnd == h) return w;
        return null;
    }
    return null;
}

pub fn setDropHint(self: *TabBar, hint: ?usize) void {
    const hwnd = self.hwnd orelse return;
    if (std.meta.eql(self.drop_hint, hint)) return;
    self.drop_hint = hint;
    if (hint != null and !c.IsWindowVisible(hwnd).toBool()) {
        if (self.window().hwnd) |parent| {
            var rect: c.RECT = .{};
            _ = c.GetClientRect(parent, &rect);
            _ = c.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, self.height(), c.SWP_SHOWWINDOW | c.SWP_NOACTIVATE);
            self.overlay = true;
        }
    } else if (hint == null and self.overlay) {
        self.overlay = false;
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
    }
    self.invalidate();
}

fn release(self: *TabBar, hwnd: c.HWND, lparam: c.LPARAM) void {
    const d = self.drag orelse return;
    if (d.float != null) return self.endDrag(true);
    if (!d.moving) return self.endDrag(true);
    var pt = c.pointFromLparam(lparam);
    _ = c.ClientToScreen(hwnd, &pt);
    if (!self.outside(hwnd, pt)) return self.endDrag(true);
    const index = self.dragIndex(d) orelse return self.endDrag(false);
    self.endDrag(true);
    self.window().dropTab(index, pt, d.grab);
}

fn outside(self: *TabBar, hwnd: c.HWND, pt: c.POINT) bool {
    const win_hwnd = self.window().hwnd orelse return false;
    var bar: c.RECT = .{};
    var win: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &bar);
    _ = c.GetWindowRect(win_hwnd, &win);
    if (!c.rectContains(win, pt.x, pt.y)) return true;
    const top = if (c.WindowFromPoint(pt)) |h| c.GetAncestor(h, c.GA_ROOT) else null;
    if (top != win_hwnd) return true;
    const margin = 2 * (bar.bottom - bar.top);
    return pt.y < bar.top - margin or pt.y >= bar.bottom + margin;
}

pub fn dropIndex(self: *TabBar, pt: c.POINT) ?usize {
    const win = self.window();
    const win_hwnd = win.hwnd orelse return null;
    const count = win.tabs.items.len;
    if (self.hwnd) |hwnd| if (c.IsWindowVisible(hwnd).toBool()) {
        var r: c.RECT = .{};
        _ = c.GetWindowRect(hwnd, &r);
        const h = r.bottom - r.top;
        if (pt.x < r.left or pt.x >= r.right) return null;
        if (pt.y < r.top - h or pt.y >= r.bottom + @divTrunc(h, 2)) return null;
        const layout = Layout.init(self) orelse return null;
        const w = @max(layout.tab_width, 1);
        const slot: usize = @intCast(@divTrunc(@max(0, pt.x - r.left) + @divTrunc(w, 2), w));
        return @min(slot, count);
    };
    var r: c.RECT = .{};
    _ = c.GetWindowRect(win_hwnd, &r);
    var origin: c.POINT = .{};
    _ = c.ClientToScreen(win_hwnd, &origin);
    if (!c.rectContains(r, pt.x, pt.y) or pt.y >= origin.y + self.height()) return null;
    return count;
}

fn endDrag(self: *TabBar, commit: bool) void {
    const d = self.drag orelse return;
    self.drag = null;
    const win = self.window();
    if (d.float == null and !commit) if (self.dragIndex(d)) |i| if (i != d.origin) {
        const delta = @as(isize, @intCast(d.origin)) - @as(isize, @intCast(i));
        _ = win.moveTab(d.surface, delta);
    };
    if (self.hwnd) |hwnd| {
        if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
        if (c.GetFocus() == hwnd) if (win.activeSurface()) |s| if (s.hwnd) |h| {
            _ = c.SetFocus(h);
        };
    }
    self.invalidate();
    if (d.float) |f| self.endFloat(d, f, commit);
}

fn endFloat(self: *TabBar, d: Drag, f: Float, commit: bool) void {
    const home = self.window();
    const app = home.app;
    var hint: ?usize = null;
    if (f.target) |t| if (alive(app, t)) {
        hint = t.tab_bar.drop_hint;
        t.tab_bar.setDropHint(null);
    };
    if (!alive(app, f.window)) return;
    const float = f.window;
    const float_hwnd = float.hwnd.?;
    const index = float.tabIndex(d.surface) orelse return;
    if (float != home) float.setTransitions(true);

    if (!commit) {
        if (float == home) {
            _ = c.SetWindowPos(float_hwnd, null, f.home.left, f.home.top, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        } else if (alive(app, home)) {
            _ = float.transferTab(index, home, d.origin);
        }
        return;
    }

    if (f.target) |t| if (hint) |at| if (alive(app, t)) {
        const target_hwnd = t.hwnd;
        if (float.transferTab(index, t, at)) {
            if (target_hwnd) |h| _ = c.SetForegroundWindow(h);
            return;
        }
    };
    _ = c.SetForegroundWindow(float_hwnd);
}

pub fn startRename(self: *TabBar, index: usize) void {
    self.endDrag(false);
    self.cancelRename(false);
    const edit = self.edit_hwnd orelse return;
    const win = self.window();
    if (index >= win.tabs.items.len) return;
    const layout = Layout.init(self) orelse return;
    if (index >= layout.count) return;

    const surface = win.tabs.items[index].focused;
    const tab_rect = layout.tab(index);
    const close_rect = layout.closeIn(tab_rect);
    const pad = c.scaleDpi(tab_padding, layout.dpi);
    const left = tab_rect.left + pad;
    const right = @max(left + c.scaleDpi(24, layout.dpi), close_rect.left - c.scaleDpi(4, layout.dpi));
    const edit_h = @max(16, layout.height - c.scaleDpi(10, layout.dpi));
    const top = @divTrunc(layout.height - edit_h, 2);

    const alloc = win.app.core_app.alloc;
    const current = win.tabTitle(index);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, current) catch return;
    defer alloc.free(wide);

    self.renaming_surface = surface;
    _ = c.SetWindowTextW(edit, wide);
    _ = c.MoveWindow(edit, left, top, right - left, edit_h, .TRUE);
    _ = c.ShowWindow(edit, c.SW_SHOW);
    _ = c.SetFocus(edit);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    self.invalidate();
}

pub fn commitRename(self: *TabBar) void {
    const surface = self.renaming_surface orelse return;
    self.renaming_surface = null;
    const edit = self.edit_hwnd orelse return;
    const win = self.window();
    const alloc = win.app.core_app.alloc;

    if (c.getWindowTextUtf8(alloc, edit)) |utf8| {
        defer alloc.free(utf8);
        win.setTabTitle(surface, utf8) catch |err| {
            log.warn("error setting tab title err={}", .{err});
        };
    } else |_| {}

    _ = c.ShowWindow(edit, c.SW_HIDE);
    self.invalidate();
    if (win.activeSurface()) |active| {
        if (active.hwnd) |shwnd| _ = c.SetFocus(shwnd);
    }
}

pub fn cancelRename(self: *TabBar, restore_focus: bool) void {
    if (self.renaming_surface == null) return;
    self.renaming_surface = null;
    if (self.edit_hwnd) |edit| _ = c.ShowWindow(edit, c.SW_HIDE);
    self.invalidate();
    if (restore_focus) {
        if (self.window().activeSurface()) |active| {
            if (active.hwnd) |shwnd| _ = c.SetFocus(shwnd);
        }
    }
}

fn editSubclassProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const self = c.userData(TabBar, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const orig = self.orig_edit_proc orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_KEYDOWN => {
            if (wparam == c.VK_RETURN) {
                self.commitRename();
                return 0;
            }
            if (wparam == c.VK_ESCAPE) {
                self.cancelRename(true);
                return 0;
            }
        },
        c.WM_CHAR => {
            if (c.isSuppressedEditChar(wparam)) return 0;
        },
        else => {},
    }
    return c.CallWindowProcW(orig, hwnd, msg, wparam, lparam);
}

fn appendMenuItem(
    alloc: std.mem.Allocator,
    menu: c.HMENU,
    flags: c.UINT,
    cmd: MenuCmd,
    label_utf8: [*:0]const u8,
    fallback: [:0]const u16,
) void {
    dialogs.appendMenuUtf8(alloc, menu, flags, @backingInt(cmd), label_utf8, fallback);
}

fn showContextMenu(self: *TabBar, hwnd: c.HWND, pt_client: c.POINT) void {
    self.endDrag(false);
    self.cancelRename(false);

    const win = self.window();
    const alloc = win.app.core_app.alloc;
    const layout = Layout.init(self) orelse return;
    const hit = layout.hit(pt_client.x, pt_client.y);

    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);

    var target_surface: ?*Surface = null;
    if (hit) |h| switch (h) {
        .tab, .close => |i| if (i < win.tabs.items.len) {
            target_surface = win.tabs.items[i].focused;
            const multi = win.tabs.items.len > 1;
            const has_right = i + 1 < win.tabs.items.len;
            appendMenuItem(alloc, menu, c.MF_STRING, .rename_tab, i18n._("Rename Tab"), L("Rename Tab"));
            appendMenuItem(alloc, menu, if (multi) c.MF_STRING else c.MF_STRING | c.MF_GRAYED, .move_to_new_window, i18n._("Move Tab to New Window"), L("Move Tab to New Window"));
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
            appendMenuItem(alloc, menu, c.MF_STRING, .close_tab, i18n._("Close Tab"), L("Close Tab"));
            appendMenuItem(alloc, menu, if (multi) c.MF_STRING else c.MF_STRING | c.MF_GRAYED, .close_other_tabs, i18n._("Close Other Tabs"), L("Close Other Tabs"));
            appendMenuItem(alloc, menu, if (has_right) c.MF_STRING else c.MF_STRING | c.MF_GRAYED, .close_tabs_right, i18n._("Close Tabs to the Right"), L("Close Tabs to the Right"));
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
            appendMenuItem(alloc, menu, c.MF_STRING, .new_tab, i18n._("New Tab"), L("New Tab"));
        },
        .new => {
            appendMenuItem(alloc, menu, c.MF_STRING, .new_tab, i18n._("New Tab"), L("New Tab"));
        },
    } else {
        appendMenuItem(alloc, menu, c.MF_STRING, .new_tab, i18n._("New Tab"), L("New Tab"));
    }

    var screen_pt = pt_client;
    _ = c.ClientToScreen(hwnd, &screen_pt);
    const cmd_raw = c.TrackPopupMenuEx(
        menu,
        c.TPM_LEFTALIGN | c.TPM_TOPALIGN | c.TPM_RIGHTBUTTON | c.TPM_RETURNCMD,
        screen_pt.x,
        screen_pt.y,
        hwnd,
        null,
    );
    const cmd_id: usize = @intCast(@as(c_int, @bitCast(cmd_raw)));
    if (cmd_id == 0) return;
    if (!alive(win.app, win)) return;

    const cmd = std.enums.fromInt(MenuCmd, cmd_id) orelse return;
    switch (cmd) {
        .new_tab => win.newTab(null),
        .rename_tab => if (target_surface) |s| if (win.tabIndex(s)) |idx| {
            self.startRename(idx);
        },
        .move_to_new_window => if (target_surface) |s| {
            _ = win.moveTabToNewWindow(s);
        },
        .close_tab => if (target_surface) |s| if (win.tabIndex(s)) |idx| {
            win.closeTabAt(idx);
        },
        .close_other_tabs => if (target_surface) |s| {
            win.closeTabs(s, .other);
        },
        .close_tabs_right => if (target_surface) |s| {
            win.closeTabs(s, .right);
        },
    }
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const self = c.initUserData(TabBar, hwnd, lparam);
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = c.userData(TabBar, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            self.cancelRename(false);
            self.invalidate();
            return 0;
        },

        c.WM_CTLCOLOREDIT => {
            const hdc: c.HDC = @ptrFromInt(wparam);
            const win = self.window();
            const palette = win.palette();
            return c.handleCtlColorEdit(hdc, palette.text, palette.active, &self.edit_brush);
        },

        c.WM_COMMAND => {
            const code: u16 = @truncate(wparam >> 16);
            const id: u16 = @truncate(wparam & 0xFFFF);
            if (id == edit_id and code == c.EN_KILLFOCUS and self.renaming_surface != null) {
                self.commitRename();
                return 0;
            }
        },

        c.WM_DPICHANGED_AFTERPARENT => {
            self.updateFont();
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (self.drag != null) {
                if (wparam & c.MK_LBUTTON != 0) self.dragTo(hwnd, lparam);
                return 0;
            }
            c.trackMouseLeave(hwnd, &self.tracking);
            self.setHover(self.hitAt(lparam));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking = false;
            self.setHover(null);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            if (self.drag != null) return 0;
            const hit = self.hitAt(lparam) orelse return 0;
            const win = self.window();
            switch (hit) {
                .tab => |i| {
                    win.selectTab(i);
                    self.beginDrag(hwnd, i, c.xFromLparam(lparam), c.yFromLparam(lparam));
                },
                .close => |i| win.closeTabAt(i),
                .new => win.newTab(null),
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            self.release(hwnd, lparam);
            return 0;
        },

        c.WM_LBUTTONDBLCLK => {
            self.endDrag(false);
            const hit = self.hitAt(lparam) orelse return 0;
            switch (hit) {
                .tab => |i| self.startRename(i),
                .close => |i| self.window().closeTabAt(i),
                .new => self.window().newTab(null),
            }
            return 0;
        },

        c.WM_RBUTTONUP => {
            self.showContextMenu(hwnd, c.pointFromLparam(lparam));
            return 0;
        },

        c.WM_CONTEXTMENU => {
            var pt = c.pointFromLparam(lparam);
            if (pt.x == -1 and pt.y == -1) {
                if (Layout.init(self)) |layout| {
                    const win = self.window();
                    const idx = @min(win.active, @max(layout.count, 1) - 1);
                    const r = layout.tab(idx);
                    pt = .{ .x = @divTrunc(r.left + r.right, 2), .y = @divTrunc(r.top + r.bottom, 2) };
                } else {
                    pt = .{ .x = 0, .y = 0 };
                }
            } else {
                _ = c.ScreenToClient(hwnd, &pt);
            }
            self.showContextMenu(hwnd, pt);
            return 0;
        },

        c.WM_KEYDOWN => {
            if (wparam == c.VK_ESCAPE and self.drag != null) {
                self.endDrag(false);
                return 0;
            }
        },

        c.WM_CAPTURECHANGED => {
            self.endDrag(false);
            return 0;
        },

        c.WM_CANCELMODE => self.endDrag(false),

        c.WM_MBUTTONUP => {
            if (self.drag != null) return 0;
            const hit = self.hitAt(lparam) orelse return 0;
            switch (hit) {
                .tab, .close => |i| self.window().closeTabAt(i),
                .new => {},
            }
            return 0;
        },

        c.WM_MOUSEWHEEL => {
            self.endDrag(false);
            self.cancelRename(false);
            const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
            if (delta > 0) {
                _ = self.window().gotoTab(.previous);
            } else if (delta < 0) {
                _ = self.window().gotoTab(.next);
            }
            return 0;
        },

        c.WM_MOUSEHWHEEL => {
            self.endDrag(false);
            self.cancelRename(false);
            const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
            if (delta < 0) {
                _ = self.window().gotoTab(.previous);
            } else if (delta > 0) {
                _ = self.window().gotoTab(.next);
            }
            return 0;
        },

        c.WM_NCDESTROY => {
            self.drag = null;
            self.drop_hint = null;
            self.renaming_surface = null;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.releaseBackbuffer();
            if (self.tooltip_hwnd) |tip| _ = c.DestroyWindow(tip);
            if (self.font) |f| _ = c.DeleteObject(f);
            if (self.edit_brush) |b| _ = c.DeleteObject(b);
            self.font = null;
            self.edit_brush = null;
            self.tooltip_hwnd = null;
            self.edit_hwnd = null;
            self.hwnd = null;
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
