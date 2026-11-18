const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const zf = @import("zf");
const input = @import("../../input.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabBar = @import("TabBar.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const class_name = L("AnittyCommandPalette");

const palette_width = 560;
const palette_max_height = 420;
const top_offset = 44;
const header_height = 44;
const row_height = 46;
const pad_x = 12;
const edit_id: usize = 1;

pub const Entry = struct {
    title: [:0]const u8,
    description: [:0]const u8,
    shortcut: ?[:0]const u8 = null,
    kind: Kind,
    sort_key: usize = 0,
    rank: ?f64 = null,

    pub const Kind = union(enum) {
        action: input.Binding.Action,
        jump: *Surface,
    };
};

hwnd: ?c.HWND = null,
edit_hwnd: ?c.HWND = null,
orig_edit_proc: ?c.WNDPROC = null,
font: ?c.HFONT = null,
bold_font: ?c.HFONT = null,
edit_brush: ?c.HBRUSH = null,
visible: bool = false,
suppress_change: bool = false,
arena: ?std.heap.ArenaAllocator = null,
entries: std.ArrayList(Entry) = .empty,
filtered: std.ArrayList(usize) = .empty,
selected: usize = 0,
scroll_offset: usize = 0,
hover: ?usize = null,
tracking: bool = false,

fn window(self: *CommandPalette) *Window {
    return @alignCast(@fieldParentPtr("command_palette", self));
}

pub fn isActionSupported(action: input.Binding.Action) bool {
    return switch (action) {
        .show_gtk_inspector => false,
        else => true,
    };
}

pub fn create(self: *CommandPalette, parent: c.HWND, instance: ?c.HINSTANCE) !void {
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

pub fn deinit(self: *CommandPalette, alloc: Allocator) void {
    self.clearEntries(alloc);
    if (self.font) |f| _ = c.DeleteObject(f);
    if (self.bold_font) |f| _ = c.DeleteObject(f);
    if (self.edit_brush) |b| _ = c.DeleteObject(b);
    self.font = null;
    self.bold_font = null;
    self.edit_brush = null;
}

fn clearEntries(self: *CommandPalette, alloc: Allocator) void {
    self.entries.deinit(alloc);
    self.filtered.deinit(alloc);
    self.entries = .empty;
    self.filtered = .empty;
    if (self.arena) |*a| {
        a.deinit();
        self.arena = null;
    }
}

pub fn updateFont(self: *CommandPalette) void {
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

pub fn invalidate(self: *CommandPalette) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

pub fn toggle(self: *CommandPalette) bool {
    if (self.visible) {
        self.hide();
        return true;
    }
    return self.show();
}

pub fn show(self: *CommandPalette) bool {
    const hwnd = self.hwnd orelse return false;
    const win = self.window();
    const alloc = win.app.core_app.alloc;

    self.populate(alloc) catch |err| {
        log.warn("failed to populate command palette err={}", .{err});
        return false;
    };

    self.visible = true;
    self.selected = 0;
    self.scroll_offset = 0;
    self.hover = null;

    if (self.edit_hwnd) |edit| {
        self.suppress_change = true;
        _ = c.SetWindowTextW(edit, L(""));
        self.suppress_change = false;
    }
    self.filterEntries("") catch {};
    self.layout();

    _ = c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_SHOWWINDOW);
    if (self.edit_hwnd) |edit| _ = c.SetFocus(edit);
    self.invalidate();
    return true;
}

pub fn hide(self: *CommandPalette) void {
    if (!self.visible) return;
    self.visible = false;
    if (self.hwnd) |hwnd| _ = c.ShowWindow(hwnd, c.SW_HIDE);
    const win = self.window();
    self.clearEntries(win.app.core_app.alloc);
    if (win.activeSurface()) |s| {
        if (s.hwnd) |shwnd| _ = c.SetFocus(shwnd);
    }
}

pub fn layout(self: *CommandPalette) void {
    const hwnd = self.hwnd orelse return;
    const win = self.window();
    const parent = win.hwnd orelse return;
    var client: c.RECT = .{};
    _ = c.GetClientRect(parent, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const dpi = c.GetDpiForWindow(hwnd);

    const w = @min(c.scaleDpi(palette_width, dpi), @max(200, cw - c.scaleDpi(32, dpi)));
    const hh = c.scaleDpi(header_height, dpi);
    const rh = c.scaleDpi(row_height, dpi);
    const visible_rows: i32 = @intCast(@min(@max(self.filtered.items.len, 1), 8));
    const desired_h = hh + visible_rows * rh + c.scaleDpi(8, dpi);
    const h = @min(@min(c.scaleDpi(palette_max_height, dpi), desired_h), @max(hh + rh, ch - c.scaleDpi(64, dpi)));
    const x = @divTrunc(cw - w, 2);
    const y = @min(c.scaleDpi(top_offset, dpi), @max(8, @divTrunc(ch - h, 4)));

    _ = c.SetWindowPos(hwnd, null, x, y, w, h, c.SWP_NOACTIVATE);
    if (self.edit_hwnd) |edit| {
        const px = c.scaleDpi(pad_x, dpi);
        const edit_h = @max(18, hh - c.scaleDpi(18, dpi));
        const edit_y = @divTrunc(hh - edit_h, 2);
        _ = c.MoveWindow(edit, px, edit_y, @max(60, w - px * 2), edit_h, .TRUE);
    }
}

fn populate(self: *CommandPalette, alloc: Allocator) !void {
    self.clearEntries(alloc);
    self.arena = .init(alloc);
    errdefer self.clearEntries(alloc);
    const arena = self.arena.?.allocator();
    const app = self.window().app;

    for (app.core_app.surfaces.items, 0..) |surface, idx| {
        if (surface.detached) continue;
        const eff = surface.getEffectiveTitle() orelse "Untitled";
        const title = try std.fmt.allocPrintSentinel(arena, "Focus: {s}", .{eff}, 0);
        const pwd = surface.getPwd() orelse "";
        const desc = if (pwd.len > 0 and std.mem.indexOf(u8, eff, pwd) == null)
            try arena.dupeSentinel(u8, pwd, 0)
        else
            try arena.dupeSentinel(u8, "Switch to terminal surface", 0);
        try self.entries.append(alloc, .{
            .title = title,
            .description = desc,
            .shortcut = null,
            .kind = .{ .jump = surface },
            .sort_key = idx,
        });
    }

    const keybinds = app.config.keybind.set;
    for (app.config.@"command-palette-entry".value.items) |cmd| {
        if (!isActionSupported(cmd.action)) continue;
        const cloned = try cmd.clone(arena);
        const shortcut: ?[:0]const u8 = if (keybinds.getTrigger(cloned.action)) |trig|
            try std.fmt.allocPrintSentinel(arena, "{f}", .{trig}, 0)
        else
            null;
        try self.entries.append(alloc, .{
            .title = cloned.title,
            .description = cloned.description,
            .shortcut = shortcut,
            .kind = .{ .action = cloned.action },
        });
    }

    std.mem.sort(Entry, self.entries.items, {}, compareEntriesDefault);
}

pub fn compareEntriesDefault(_: void, a: Entry, b: Entry) bool {
    for (0..@min(a.title.len, b.title.len)) |i| {
        const ac = if (a.title[i] == ':') '\t' else std.ascii.toLower(a.title[i]);
        const bc = if (b.title[i] == ':') '\t' else std.ascii.toLower(b.title[i]);
        if (ac != bc) return ac < bc;
    }
    if (a.title.len != b.title.len) return a.title.len < b.title.len;
    return a.sort_key < b.sort_key;
}

pub fn filterEntries(self: *CommandPalette, query: []const u8) !void {
    const alloc = self.window().app.core_app.alloc;
    self.filtered.clearRetainingCapacity();

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        for (self.entries.items, 0..) |*e, i| {
            e.rank = null;
            try self.filtered.append(alloc, i);
        }
    } else {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(alloc);
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        while (it.next()) |tok| try tokens.append(alloc, tok);

        for (self.entries.items, 0..) |*e, i| {
            const title_rank = zf.rank(e.title, tokens.items, .{
                .case_sensitive = false,
                .plain = true,
            });
            const desc_rank = if (e.description.len > 0)
                zf.rank(e.description, tokens.items, .{
                    .case_sensitive = false,
                    .plain = true,
                })
            else
                null;
            e.rank = if (title_rank) |tr|
                tr
            else if (desc_rank) |dr|
                dr + 10.0
            else
                null;
            if (e.rank != null) try self.filtered.append(alloc, i);
        }

        const Context = struct {
            items: []const Entry,
            pub fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                const a = ctx.items[a_idx];
                const b = ctx.items[b_idx];
                const ar = a.rank orelse std.math.inf(f64);
                const br = b.rank orelse std.math.inf(f64);
                if (!std.math.approxEqAbs(f64, ar, br, 1e-6)) return ar < br;
                return compareEntriesDefault({}, a, b);
            }
        };
        std.mem.sort(usize, self.filtered.items, Context{ .items = self.entries.items }, Context.lessThan);
    }

    self.selected = 0;
    self.scroll_offset = 0;
    self.hover = null;
}

fn onQueryChanged(self: *CommandPalette) void {
    const edit = self.edit_hwnd orelse return;
    const alloc = self.window().app.core_app.alloc;
    const utf8 = c.getWindowTextUtf8(alloc, edit) catch return;
    defer alloc.free(utf8);
    self.filterEntries(utf8) catch {};
    self.layout();
    self.invalidate();
}

fn visibleRowCount(self: *const CommandPalette) usize {
    const hwnd = self.hwnd orelse return 1;
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const dpi = c.GetDpiForWindow(hwnd);
    const hh = c.scaleDpi(header_height, dpi);
    const rh = @max(1, c.scaleDpi(row_height, dpi));
    const avail = @max(0, (r.bottom - r.top) - hh);
    return @intCast(@max(1, @divTrunc(avail, rh)));
}

fn moveSelection(self: *CommandPalette, delta: isize) void {
    const total = self.filtered.items.len;
    if (total == 0) return;
    const cur: isize = @intCast(self.selected);
    const max: isize = @intCast(total - 1);
    self.selected = @intCast(std.math.clamp(cur + delta, 0, max));
    const vis = self.visibleRowCount();
    if (self.selected < self.scroll_offset) {
        self.scroll_offset = self.selected;
    } else if (self.selected >= self.scroll_offset + vis) {
        self.scroll_offset = self.selected - vis + 1;
    }
    self.invalidate();
}

fn activateSelected(self: *CommandPalette) void {
    if (self.selected >= self.filtered.items.len) {
        self.hide();
        return;
    }
    const win = self.window();
    const alloc = win.app.core_app.alloc;
    const entry = self.entries.items[self.filtered.items[self.selected]];
    switch (entry.kind) {
        .jump => |target_surface| {
            self.hide();
            for (win.app.core_app.surfaces.items) |s| {
                if (s == target_surface) {
                    target_surface.present();
                    break;
                }
            }
        },
        .action => |act| {
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const cloned = act.clone(arena.allocator()) catch {
                self.hide();
                return;
            };
            self.hide();
            if (win.activeSurface()) |s| {
                if (s.initialized) {
                    _ = s.core_surface.performBindingAction(cloned) catch |err| {
                        log.warn("command palette action failed err={}", .{err});
                    };
                }
            }
        },
    }
}

fn rowAtY(self: *const CommandPalette, y: i32) ?usize {
    const hwnd = self.hwnd orelse return null;
    const dpi = c.GetDpiForWindow(hwnd);
    const hh = c.scaleDpi(header_height, dpi);
    if (y < hh) return null;
    const rh = @max(1, c.scaleDpi(row_height, dpi));
    const idx = self.scroll_offset + @as(usize, @intCast(@divTrunc(y - hh, rh)));
    if (idx >= self.filtered.items.len) return null;
    return idx;
}

fn paint(self: *CommandPalette, hwnd: c.HWND) void {
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
    const hh = c.scaleDpi(header_height, dpi);
    const rh = c.scaleDpi(row_height, dpi);
    const px = c.scaleDpi(pad_x, dpi);

    c.fillRectColor(mem, rect, palette.bar);
    c.fillRectColor(mem, .{ .left = 0, .top = hh - 1, .right = w, .bottom = hh }, palette.separator);
    c.drawRectBorder(mem, rect, palette.separator);

    _ = c.SetBkMode(mem, c.TRANSPARENT);

    if (self.filtered.items.len == 0) {
        const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
        defer if (old_font) |o| {
            _ = c.SelectObject(mem, o);
        };
        _ = c.SetTextColor(mem, palette.text_inactive);
        var empty_r: c.RECT = .{ .left = px, .top = hh, .right = w - px, .bottom = h };
        const msg = L("No matching commands");
        _ = c.DrawTextW(mem, msg.ptr, @intCast(msg.len), &empty_r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
        _ = c.BitBlt(hdc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
        return;
    }

    const vis = self.visibleRowCount();
    const end = @min(self.filtered.items.len, self.scroll_offset + vis + 1);
    for (self.scroll_offset..end) |row_idx| {
        const entry = self.entries.items[self.filtered.items[row_idx]];
        const top = hh + @as(i32, @intCast(row_idx - self.scroll_offset)) * rh;
        const row_r: c.RECT = .{ .left = 1, .top = top, .right = w - 1, .bottom = @min(h - 1, top + rh) };
        if (row_r.top >= h - 1) break;

        const is_sel = row_idx == self.selected;
        const is_hov = if (self.hover) |hv| hv == row_idx else false;
        if (is_sel) {
            c.fillRectColor(mem, row_r, palette.active);
        } else if (is_hov) {
            c.fillRectColor(mem, row_r, palette.hover);
        }

        var right_limit = w - px;
        if (entry.shortcut) |sc| {
            const old_f = if (self.font) |f| c.SelectObject(mem, f) else null;
            defer if (old_f) |o| {
                _ = c.SelectObject(mem, o);
            };
            _ = c.SetTextColor(mem, palette.text_inactive);
            if (std.unicode.utf8ToUtf16LeAlloc(alloc, sc)) |wide_sc| {
                defer alloc.free(wide_sc);
                const sc_w = @min(c.scaleDpi(160, dpi), @as(i32, @intCast(wide_sc.len)) * c.scaleDpi(8, dpi) + c.scaleDpi(12, dpi));
                var sc_r: c.RECT = .{
                    .left = right_limit - sc_w,
                    .top = top,
                    .right = right_limit,
                    .bottom = top + rh,
                };
                _ = c.DrawTextW(mem, wide_sc.ptr, @intCast(wide_sc.len), &sc_r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_RIGHT | c.DT_NOPREFIX);
                right_limit = sc_r.left - c.scaleDpi(8, dpi);
            } else |_| {}
        }

        const title_font = self.bold_font orelse self.font;
        {
            const old_f = if (title_font) |f| c.SelectObject(mem, f) else null;
            defer if (old_f) |o| {
                _ = c.SelectObject(mem, o);
            };
            _ = c.SetTextColor(mem, palette.text);
            if (std.unicode.utf8ToUtf16LeAlloc(alloc, entry.title)) |wide_t| {
                defer alloc.free(wide_t);
                var title_r: c.RECT = .{
                    .left = px,
                    .top = top + c.scaleDpi(4, dpi),
                    .right = right_limit,
                    .bottom = if (entry.description.len > 0) top + @divTrunc(rh, 2) + c.scaleDpi(2, dpi) else top + rh - c.scaleDpi(4, dpi),
                };
                _ = c.DrawTextW(mem, wide_t.ptr, @intCast(wide_t.len), &title_r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
            } else |_| {}
        }

        if (entry.description.len > 0) {
            const old_f = if (self.font) |f| c.SelectObject(mem, f) else null;
            defer if (old_f) |o| {
                _ = c.SelectObject(mem, o);
            };
            _ = c.SetTextColor(mem, palette.text_inactive);
            if (std.unicode.utf8ToUtf16LeAlloc(alloc, entry.description)) |wide_d| {
                defer alloc.free(wide_d);
                var desc_r: c.RECT = .{
                    .left = px,
                    .top = top + @divTrunc(rh, 2),
                    .right = right_limit,
                    .bottom = top + rh - c.scaleDpi(4, dpi),
                };
                _ = c.DrawTextW(mem, wide_d.ptr, @intCast(wide_d.len), &desc_r, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_LEFT | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
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
    const self = c.userData(CommandPalette, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const orig = self.orig_edit_proc orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_DOWN => {
                self.moveSelection(1);
                return 0;
            },
            c.VK_UP => {
                self.moveSelection(-1);
                return 0;
            },
            c.VK_NEXT => {
                self.moveSelection(@intCast(self.visibleRowCount()));
                return 0;
            },
            c.VK_PRIOR => {
                self.moveSelection(-@as(isize, @intCast(self.visibleRowCount())));
                return 0;
            },
            c.VK_RETURN => {
                self.activateSelected();
                return 0;
            },
            c.VK_ESCAPE => {
                self.hide();
                return 0;
            },
            else => {},
        },
        c.WM_CHAR => {
            if (c.isSuppressedEditChar(wparam)) return 0;
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
        const self = c.initUserData(CommandPalette, hwnd, lparam);
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = c.userData(CommandPalette, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

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
            return c.handleCtlColorEdit(hdc, palette.text, palette.active, &self.edit_brush);
        },
        c.WM_COMMAND => {
            const code: u16 = @truncate(wparam >> 16);
            const id: u16 = @truncate(wparam & 0xFFFF);
            if (id == edit_id and code == c.EN_CHANGE and !self.suppress_change) {
                self.onQueryChanged();
                return 0;
            }
        },
        c.WM_MOUSEMOVE => {
            c.trackMouseLeave(hwnd, &self.tracking);
            const next = self.rowAtY(c.yFromLparam(lparam));
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
        c.WM_LBUTTONUP => {
            const y = c.yFromLparam(lparam);
            if (self.rowAtY(y)) |idx| {
                self.selected = idx;
                self.activateSelected();
            }
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
            if (delta < 0) self.moveSelection(1) else if (delta > 0) self.moveSelection(-1);
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

test "CommandPalette compareEntriesDefault" {
    const testing = std.testing;
    const a: Entry = .{
        .title = "Focus: alpha",
        .description = "",
        .kind = .{ .action = .quit },
        .sort_key = 1,
    };
    const b: Entry = .{
        .title = "Focus Bar: beta",
        .description = "",
        .kind = .{ .action = .quit },
        .sort_key = 2,
    };
    try testing.expect(compareEntriesDefault({}, a, b));
}
