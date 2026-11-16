const TabOverview = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const zf = @import("zf");
const App = @import("App.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const class_name = L("AnittyTabOverview");

const top_bar_height = 56;
const search_width = 320;
const search_height = 28;
const grid_pad = 24;
const card_gap = 16;
const card_min_width = 220;
const card_max_width = 320;
const card_height = 120;
const close_btn_size = 22;
const new_btn_width = 96;
const new_btn_height = 28;
const edit_id: usize = 1;

const Hit = union(enum) {
    card: usize,
    close: usize,
    new_tab,
};

pub const GridMetrics = struct {
    cols: usize,
    card_w: i32,
    card_h: i32,
    gap: i32,
    start_x: i32,
    start_y: i32,

    pub fn compute(avail_w: i32, top_y: i32, dpi: c.UINT) GridMetrics {
        const pad = c.scaleDpi(grid_pad, dpi);
        const gap = c.scaleDpi(card_gap, dpi);
        const min_w = @max(1, c.scaleDpi(card_min_width, dpi));
        const max_w = @max(min_w, c.scaleDpi(card_max_width, dpi));
        const ch = c.scaleDpi(card_height, dpi);
        const inner_w = @max(min_w, avail_w - pad * 2);
        const cols: usize = @intCast(@max(1, @min(4, @divTrunc(inner_w + gap, min_w + gap))));
        const cols_i32: i32 = @intCast(cols);
        const raw_w = @divTrunc(inner_w - gap * (cols_i32 - 1), cols_i32);
        const cw = std.math.clamp(raw_w, min_w, max_w);
        const total_w = cw * cols_i32 + gap * (cols_i32 - 1);
        const sx = @max(pad, @divTrunc(avail_w - total_w, 2));
        return .{
            .cols = cols,
            .card_w = cw,
            .card_h = ch,
            .gap = gap,
            .start_x = sx,
            .start_y = top_y + pad,
        };
    }

    pub fn cardRect(self: GridMetrics, slot: usize, scroll_y: i32) c.RECT {
        const col: i32 = @intCast(slot % self.cols);
        const row: i32 = @intCast(slot / self.cols);
        const left = self.start_x + col * (self.card_w + self.gap);
        const top = self.start_y + row * (self.card_h + self.gap) - scroll_y;
        return .{
            .left = left,
            .top = top,
            .right = left + self.card_w,
            .bottom = top + self.card_h,
        };
    }
};

hwnd: ?c.HWND = null,
edit_hwnd: ?c.HWND = null,
orig_edit_proc: ?c.WNDPROC = null,
font: ?c.HFONT = null,
bold_font: ?c.HFONT = null,
edit_brush: ?c.HBRUSH = null,
visible: bool = false,
suppress_change: bool = false,
filtered: std.ArrayList(usize) = .empty,
selected: usize = 0,
scroll_y: i32 = 0,
hover: ?Hit = null,
tracking: bool = false,

fn window(self: *TabOverview) *Window {
    return @alignCast(@fieldParentPtr("tab_overview", self));
}

pub fn create(self: *TabOverview, parent: c.HWND, instance: ?c.HINSTANCE) !void {
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

pub fn deinit(self: *TabOverview, alloc: Allocator) void {
    self.filtered.deinit(alloc);
    self.filtered = .empty;
    if (self.font) |f| _ = c.DeleteObject(f);
    if (self.bold_font) |f| _ = c.DeleteObject(f);
    if (self.edit_brush) |b| _ = c.DeleteObject(b);
    self.font = null;
    self.bold_font = null;
    self.edit_brush = null;
}

pub fn updateFont(self: *TabOverview) void {
    const hwnd = self.hwnd orelse return;
    var ncm: c.NONCLIENTMETRICSW = .{};
    const dpi = c.GetDpiForWindow(hwnd);
    if (!c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi).toBool()) return;
    const font = c.CreateFontIndirectW(&ncm.lfMessageFont) orelse return;
    if (self.font) |old| _ = c.DeleteObject(old);
    self.font = font;

    var bold_lf = ncm.lfMessageFont;
    bold_lf.lfWeight = 600;
    if (c.CreateFontIndirectW(&bold_lf)) |bf| {
        if (self.bold_font) |old| _ = c.DeleteObject(old);
        self.bold_font = bf;
    }

    if (self.edit_hwnd) |edit| {
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(font), 1);
    }
    self.layout();
    self.invalidate();
}

pub fn invalidate(self: *TabOverview) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn toggle(self: *TabOverview) bool {
    if (self.visible) {
        self.hide();
        return true;
    }
    return self.show();
}

pub fn show(self: *TabOverview) bool {
    const hwnd = self.hwnd orelse return false;
    const win = self.window();

    self.visible = true;
    self.scroll_y = 0;
    self.hover = null;
    if (self.edit_hwnd) |edit| {
        self.suppress_change = true;
        _ = c.SetWindowTextW(edit, L(""));
        self.suppress_change = false;
    }
    self.refreshFilter();
    for (self.filtered.items, 0..) |tab_idx, slot| {
        if (tab_idx == win.active) {
            self.selected = slot;
            break;
        }
    }
    self.layout();
    _ = c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_SHOWWINDOW);
    if (self.edit_hwnd) |edit| _ = c.SetFocus(edit);
    self.invalidate();
    return true;
}

pub fn hide(self: *TabOverview) void {
    if (!self.visible) return;
    self.visible = false;
    if (self.hwnd) |hwnd| _ = c.ShowWindow(hwnd, c.SW_HIDE);
    const win = self.window();
    if (win.activeSurface()) |s| {
        if (s.hwnd) |shwnd| _ = c.SetFocus(shwnd);
    }
}

pub fn layout(self: *TabOverview) void {
    const hwnd = self.hwnd orelse return;
    const win = self.window();
    const content = win.contentRect(win.tabs.items.len);
    const w = @max(0, content.right - content.left);
    const h = @max(0, content.bottom - content.top);
    _ = c.SetWindowPos(
        hwnd,
        null,
        content.left,
        content.top,
        w,
        h,
        c.SWP_NOACTIVATE,
    );
    if (self.edit_hwnd) |edit| {
        const dpi = c.GetDpiForWindow(hwnd);
        const tbh = c.scaleDpi(top_bar_height, dpi);
        const sw = @min(c.scaleDpi(search_width, dpi), @max(120, w - c.scaleDpi(180, dpi)));
        const sh = c.scaleDpi(search_height, dpi);
        const sx = @divTrunc(w - sw, 2);
        const sy = @divTrunc(tbh - sh, 2);
        _ = c.MoveWindow(edit, sx, sy, sw, sh, .TRUE);
    }
}

pub fn refreshFilter(self: *TabOverview) void {
    const win = self.window();
    const alloc = win.app.core_app.alloc;
    self.filtered.clearRetainingCapacity();

    const query_utf8: ?[:0]u8 = if (self.edit_hwnd) |edit|
        c.getWindowTextUtf8(alloc, edit) catch null
    else
        null;
    defer if (query_utf8) |q| alloc.free(q);

    const trimmed = std.mem.trim(u8, query_utf8 orelse "", " \t\r\n");
    if (trimmed.len == 0) {
        for (0..win.tabs.items.len) |i| {
            self.filtered.append(alloc, i) catch break;
        }
    } else {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(alloc);
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        while (it.next()) |tok| tokens.append(alloc, tok) catch break;

        for (win.tabs.items, 0..) |tab, i| {
            const title = win.tabTitle(i);
            const pwd = tab.focused.getPwd() orelse "";
            const match_title = zf.rank(title, tokens.items, .{ .case_sensitive = false, .plain = true }) != null;
            const match_pwd = pwd.len > 0 and zf.rank(pwd, tokens.items, .{ .case_sensitive = false, .plain = true }) != null;
            if (match_title or match_pwd) {
                self.filtered.append(alloc, i) catch break;
            }
        }
    }

    if (self.selected >= self.filtered.items.len) {
        self.selected = if (self.filtered.items.len > 0) self.filtered.items.len - 1 else 0;
    }
}

fn newTabButtonRect(hwnd: c.HWND) c.RECT {
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const dpi = c.GetDpiForWindow(hwnd);
    const tbh = c.scaleDpi(top_bar_height, dpi);
    const bw = c.scaleDpi(new_btn_width, dpi);
    const bh = c.scaleDpi(new_btn_height, dpi);
    const right = r.right - c.scaleDpi(grid_pad, dpi);
    const top = @divTrunc(tbh - bh, 2);
    return .{ .left = right - bw, .top = top, .right = right, .bottom = top + bh };
}

fn closeRectInCard(card: c.RECT, dpi: c.UINT) c.RECT {
    const cs = c.scaleDpi(close_btn_size, dpi);
    const m = c.scaleDpi(8, dpi);
    return .{
        .left = card.right - m - cs,
        .top = card.top + m,
        .right = card.right - m,
        .bottom = card.top + m + cs,
    };
}

fn hitAt(self: *const TabOverview, hwnd: c.HWND, x: i32, y: i32) ?Hit {
    if (c.rectContains(newTabButtonRect(hwnd), x, y)) {
        return .new_tab;
    }
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const dpi = c.GetDpiForWindow(hwnd);
    const tbh = c.scaleDpi(top_bar_height, dpi);
    if (y < tbh) return null;
    const gm = GridMetrics.compute(r.right - r.left, tbh, dpi);
    for (0..self.filtered.items.len) |slot| {
        const cr = gm.cardRect(slot, self.scroll_y);
        if (c.rectContains(cr, x, y)) {
            if (c.rectContains(closeRectInCard(cr, dpi), x, y)) {
                return .{ .close = slot };
            }
            return .{ .card = slot };
        }
    }
    return null;
}

fn moveSelection(self: *TabOverview, delta: isize) void {
    const total = self.filtered.items.len;
    if (total == 0) return;
    const cur: isize = @intCast(self.selected);
    const max: isize = @intCast(total - 1);
    self.selected = @intCast(std.math.clamp(cur + delta, 0, max));
    self.invalidate();
}

fn activateSlot(self: *TabOverview, slot: usize) void {
    if (slot >= self.filtered.items.len) return;
    const tab_idx = self.filtered.items[slot];
    const win = self.window();
    self.hide();
    win.selectTab(tab_idx);
}

fn paint(self: *TabOverview, hwnd: c.HWND) void {
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

    const win = self.window();
    const alloc = win.app.core_app.alloc;
    const palette = TabBar.Palette.init(&win.app.config);
    const dpi = c.GetDpiForWindow(hwnd);
    const tbh = c.scaleDpi(top_bar_height, dpi);

    c.fillRectColor(mem, rect, palette.active);
    c.fillRectColor(mem, .{ .left = 0, .top = 0, .right = w, .bottom = tbh }, palette.bar);
    c.fillRectColor(mem, .{ .left = 0, .top = tbh - 1, .right = w, .bottom = tbh }, palette.separator);

    _ = c.SetBkMode(mem, c.TRANSPARENT);

    const new_r = newTabButtonRect(hwnd);
    const new_hov = if (self.hover) |hv| hv == .new_tab else false;
    c.fillRectColor(mem, new_r, if (new_hov) palette.hover else palette.active);
    c.drawRectBorder(mem, new_r, palette.separator);
    {
        const old_f = if (self.font) |f| c.SelectObject(mem, f) else null;
        defer if (old_f) |o| {
            _ = c.SelectObject(mem, o);
        };
        _ = c.SetTextColor(mem, palette.text);
        var nr = new_r;
        const label = L("+ New Tab");
        _ = c.DrawTextW(mem, label.ptr, @intCast(label.len), &nr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
    }

    const gm = GridMetrics.compute(w, tbh, dpi);
    for (self.filtered.items, 0..) |tab_idx, slot| {
        if (tab_idx >= win.tabs.items.len) continue;
        const cr = gm.cardRect(slot, self.scroll_y);
        if (cr.bottom < tbh or cr.top >= h) continue;

        const is_sel = slot == self.selected;
        const is_active = tab_idx == win.active;
        const is_hov = if (self.hover) |hv| switch (hv) {
            .card, .close => |s| s == slot,
            .new_tab => false,
        } else false;

        c.fillRectColor(mem, cr, if (is_sel or is_hov) palette.hover else palette.bar);
        c.drawRectBorder(mem, cr, if (is_sel or is_active) palette.text else palette.separator);

        const pad = c.scaleDpi(12, dpi);
        const close_r = closeRectInCard(cr, dpi);
        const close_hov = if (self.hover) |hv| switch (hv) {
            .close => |s| s == slot,
            else => false,
        } else false;
        if (close_hov) c.fillRectColor(mem, close_r, palette.separator);
        c.drawCrossGlyph(mem, close_r, if (close_hov) palette.text else palette.text_inactive, c.scaleDpi(8, dpi), false);

        const title_font = self.bold_font orelse self.font;
        {
            const old_f = if (title_font) |f| c.SelectObject(mem, f) else null;
            defer if (old_f) |o| {
                _ = c.SelectObject(mem, o);
            };
            _ = c.SetTextColor(mem, palette.text);
            const raw_title = win.tabTitle(tab_idx);
            if (std.fmt.allocPrint(alloc, "#{d}  {s}", .{ tab_idx + 1, raw_title })) |header_txt| {
                defer alloc.free(header_txt);
                if (std.unicode.utf8ToUtf16LeAlloc(alloc, header_txt)) |wide| {
                    defer alloc.free(wide);
                    var tr: c.RECT = .{
                        .left = cr.left + pad,
                        .top = cr.top + c.scaleDpi(10, dpi),
                        .right = close_r.left - c.scaleDpi(6, dpi),
                        .bottom = cr.top + c.scaleDpi(36, dpi),
                    };
                    _ = c.DrawTextW(mem, wide.ptr, @intCast(wide.len), &tr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
                } else |_| {}
            } else |_| {}
        }

        {
            const old_f = if (self.font) |f| c.SelectObject(mem, f) else null;
            defer if (old_f) |o| {
                _ = c.SelectObject(mem, o);
            };
            _ = c.SetTextColor(mem, palette.text_inactive);
            const tab = win.tabs.items[tab_idx];
            const pwd = tab.focused.getPwd() orelse "";
            if (pwd.len > 0) {
                if (std.unicode.utf8ToUtf16LeAlloc(alloc, pwd)) |wide_pwd| {
                    defer alloc.free(wide_pwd);
                    var pr: c.RECT = .{
                        .left = cr.left + pad,
                        .top = cr.top + c.scaleDpi(42, dpi),
                        .right = cr.right - pad,
                        .bottom = cr.top + c.scaleDpi(68, dpi),
                    };
                    _ = c.DrawTextW(mem, wide_pwd.ptr, @intCast(wide_pwd.len), &pr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
                } else |_| {}
            }

            var leaves: usize = 0;
            var it = tab.tree.iterator();
            while (it.next()) |_| leaves += 1;
            var info_buf: [64]u8 = undefined;
            const info_str = if (leaves > 1)
                std.fmt.bufPrint(&info_buf, "{d} split panes", .{leaves}) catch ""
            else if (is_active)
                "Active tab"
            else
                "1 pane";
            var wide_info: [64]u16 = undefined;
            if (std.unicode.utf8ToUtf16Le(&wide_info, info_str)) |n| {
                var ir: c.RECT = .{
                    .left = cr.left + pad,
                    .top = cr.bottom - c.scaleDpi(32, dpi),
                    .right = cr.right - pad,
                    .bottom = cr.bottom - c.scaleDpi(8, dpi),
                };
                _ = c.DrawTextW(mem, &wide_info, @intCast(n), &ir, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX);
            } else |_| {}
        }
    }

    _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn editSubclassProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    const self = c.userData(TabOverview, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const orig = self.orig_edit_proc orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_RIGHT, c.VK_DOWN => {
                self.moveSelection(1);
                return 0;
            },
            c.VK_LEFT, c.VK_UP => {
                self.moveSelection(-1);
                return 0;
            },
            c.VK_RETURN => {
                self.activateSlot(self.selected);
                return 0;
            },
            c.VK_ESCAPE => {
                self.hide();
                return 0;
            },
            else => {},
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
        const self = c.initUserData(TabOverview, hwnd, lparam);
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = c.userData(TabOverview, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_CTLCOLOREDIT => {
            const hdc: c.HDC = @ptrFromInt(wparam);
            const win = self.window();
            const palette = TabBar.Palette.init(&win.app.config);
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
                self.refreshFilter();
                self.invalidate();
                return 0;
            }
        },
        c.WM_MOUSEMOVE => {
            c.trackMouseLeave(hwnd, &self.tracking);
            const next = self.hitAt(hwnd, c.xFromLparam(lparam), c.yFromLparam(lparam));
            if (!std.meta.eql(self.hover, next)) {
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
        c.WM_LBUTTONUP => {
            if (self.hitAt(hwnd, c.xFromLparam(lparam), c.yFromLparam(lparam))) |hit| {
                const win = self.window();
                switch (hit) {
                    .card => |slot| self.activateSlot(slot),
                    .close => |slot| {
                        if (slot < self.filtered.items.len) {
                            const tab_idx = self.filtered.items[slot];
                            win.closeTabAt(tab_idx);
                            if (win.hwnd != null) {
                                self.refreshFilter();
                                self.invalidate();
                            }
                        }
                    },
                    .new_tab => {
                        self.hide();
                        win.newTab(null);
                    },
                }
            }
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.hwnd = null;
            self.edit_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "TabOverview GridMetrics" {
    const testing = std.testing;
    const gm = GridMetrics.compute(1000, 56, 96);
    try testing.expect(gm.cols >= 3);
    const r0 = gm.cardRect(0, 0);
    const r1 = gm.cardRect(1, 0);
    try testing.expect(r1.left > r0.right);
}
