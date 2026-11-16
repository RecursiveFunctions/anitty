const UndoHistory = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const SplitView = @import("SplitView.zig");
const c = @import("c.zig");

pub const timer_id: c.UINT_PTR = 3;

pub const SavedTab = struct {
    tree: SplitView.Tree,
    focused: *Surface,
    title_override: ?[:0]const u8 = null,
    index: usize,

    pub fn deinit(self: *SavedTab, alloc: Allocator) void {
        if (self.title_override) |v| alloc.free(v);
        self.tree.deinit();
    }
};

pub const SplitOp = struct {
    tree: SplitView.Tree,
    focused: *Surface,
    anchor: *Surface,
    expected_count: usize,

    pub fn deinit(self: *SplitOp) void {
        self.tree.deinit();
    }
};

fn countLeaves(tree: *const SplitView.Tree) usize {
    var n: usize = 0;
    var it = tree.iterator();
    while (it.next()) |_| n += 1;
    return n;
}

fn isSubset(smaller: *const SplitView.Tree, larger: *const SplitView.Tree) bool {
    var it = smaller.iterator();
    while (it.next()) |node| {
        if (larger.locate(node.view) == null) return false;
    }
    return true;
}

pub const CloseTabsOp = struct {
    window: *Window,
    tabs: []SavedTab,
    was_active: ?*Surface,

    pub fn deinit(self: *CloseTabsOp, alloc: Allocator) void {
        for (self.tabs) |*t| t.deinit(alloc);
        alloc.free(self.tabs);
    }
};

pub const ReopenTabsOp = struct {
    window: *Window,
    surfaces: []*Surface,
    was_active: ?*Surface,

    pub fn deinit(self: *ReopenTabsOp, alloc: Allocator) void {
        alloc.free(self.surfaces);
    }
};

pub const CloseWindowOp = struct {
    rect: c.RECT,
    active: usize,
    title_override: ?[:0]const u8 = null,
    decorations_override: ?bool = null,
    opaque_override: bool = false,
    tabs: []SavedTab,

    pub fn deinit(self: *CloseWindowOp, alloc: Allocator) void {
        if (self.title_override) |v| alloc.free(v);
        for (self.tabs) |*t| t.deinit(alloc);
        alloc.free(self.tabs);
    }
};

pub const ReopenWindowOp = struct {
    window: *Window,
};

pub const Entry = struct {
    expires_ms: u64,
    op: Op,

    pub const Op = union(enum) {
        split: SplitOp,
        close_tabs: CloseTabsOp,
        reopen_tabs: ReopenTabsOp,
        close_window: CloseWindowOp,
        reopen_window: ReopenWindowOp,
    };

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.op) {
            .split => |*s| s.deinit(),
            .close_tabs => |*ct| ct.deinit(alloc),
            .reopen_tabs => |*rt| rt.deinit(alloc),
            .close_window => |*cw| cw.deinit(alloc),
            .reopen_window => {},
        }
    }
};

undo_stack: std.ArrayList(Entry) = .empty,
redo_stack: std.ArrayList(Entry) = .empty,
timer_armed: bool = false,

pub fn enabled(self: *const UndoHistory, app: *const App) bool {
    _ = self;
    if (app.quitting) return false;
    return app.config.@"undo-timeout".asMilliseconds() > 0;
}

fn timeoutMs(app: *const App) u64 {
    return app.config.@"undo-timeout".asMilliseconds();
}

pub fn deinit(self: *UndoHistory, app: *App) void {
    const alloc = app.core_app.alloc;
    self.disarmTimer(app);
    self.clearStack(alloc, &self.undo_stack);
    self.clearStack(alloc, &self.redo_stack);
    self.undo_stack.deinit(alloc);
    self.redo_stack.deinit(alloc);
    self.* = .{};
}

fn clearStack(self: *UndoHistory, alloc: Allocator, stack: *std.ArrayList(Entry)) void {
    _ = self;
    while (stack.pop()) |item| {
        var entry = item;
        entry.deinit(alloc);
    }
}

fn syncTimer(self: *UndoHistory, app: *App) void {
    const hwnd = app.msg_hwnd orelse return;
    const now = c.GetTickCount64();
    var earliest: ?u64 = null;
    for (self.undo_stack.items) |item| {
        earliest = if (earliest) |e| @min(e, item.expires_ms) else item.expires_ms;
    }
    for (self.redo_stack.items) |item| {
        earliest = if (earliest) |e| @min(e, item.expires_ms) else item.expires_ms;
    }

    const next = earliest orelse {
        self.disarmTimer(app);
        return;
    };

    const delay_u64 = if (next > now) next - now else 10;
    const delay: c.UINT = @intCast(@min(delay_u64, std.math.maxInt(c.UINT)));
    if (c.SetTimer(hwnd, timer_id, @max(10, delay), null) != 0) {
        self.timer_armed = true;
    }
}

fn disarmTimer(self: *UndoHistory, app: *App) void {
    if (!self.timer_armed) return;
    self.timer_armed = false;
    if (app.msg_hwnd) |hwnd| _ = c.KillTimer(hwnd, timer_id);
}

pub fn tickTimer(self: *UndoHistory, app: *App) void {
    const alloc = app.core_app.alloc;
    const now = c.GetTickCount64();
    purgeExpired(alloc, &self.undo_stack, now);
    purgeExpired(alloc, &self.redo_stack, now);
    self.syncTimer(app);
}

fn purgeExpired(alloc: Allocator, stack: *std.ArrayList(Entry), now: u64) void {
    var i: usize = 0;
    while (i < stack.items.len) {
        if (stack.items[i].expires_ms <= now) {
            var removed = stack.orderedRemove(i);
            removed.deinit(alloc);
        } else {
            i += 1;
        }
    }
}

fn pushUndo(self: *UndoHistory, app: *App, op: Entry.Op) void {
    const alloc = app.core_app.alloc;
    var entry: Entry = .{
        .expires_ms = c.GetTickCount64() + timeoutMs(app),
        .op = op,
    };
    self.clearStack(alloc, &self.redo_stack);
    self.undo_stack.append(alloc, entry) catch {
        entry.deinit(alloc);
        return;
    };
    self.syncTimer(app);
}

pub fn recordCloseSplit(
    self: *UndoHistory,
    app: *App,
    old_tree: *const SplitView.Tree,
    closed_surface: *Surface,
    anchor_surface: *Surface,
) void {
    if (!self.enabled(app)) return;
    const old_count = countLeaves(old_tree);
    if (old_count <= 1) return;
    const alloc = app.core_app.alloc;
    const cloned = old_tree.clone(alloc) catch return;
    closed_surface.detachFromWindow();
    self.pushUndo(app, .{
        .split = .{
            .tree = cloned,
            .focused = closed_surface,
            .anchor = anchor_surface,
            .expected_count = old_count - 1,
        },
    });
}

pub fn recordCloseTabs(
    self: *UndoHistory,
    window: *Window,
    saved: []SavedTab,
    was_active: ?*Surface,
) bool {
    const app = window.app;
    if (!self.enabled(app)) return false;
    for (saved) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.detachFromWindow();
    }
    self.pushUndo(app, .{
        .close_tabs = .{
            .window = window,
            .tabs = saved,
            .was_active = was_active,
        },
    });
    return true;
}

pub fn recordCloseWindow(self: *UndoHistory, window: *Window) void {
    const app = window.app;
    if (!self.enabled(app)) return;
    const cw = captureWindowOp(app.core_app.alloc, window) orelse return;
    self.pushUndo(app, .{ .close_window = cw });
}

fn captureWindowOp(alloc: Allocator, window: *Window) ?CloseWindowOp {
    if (window.tabs.items.len == 0) return null;

    const saved = alloc.alloc(SavedTab, window.tabs.items.len) catch return null;
    for (window.tabs.items, 0..) |tab, i| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.detachFromWindow();
        saved[i] = .{
            .tree = tab.tree,
            .focused = tab.focused,
            .title_override = tab.title_override,
            .index = i,
        };
    }

    var rect: c.RECT = .{};
    if (window.hwnd) |hwnd| _ = c.GetWindowRect(hwnd, &rect);
    const active = window.active;
    const title_override = window.title_override;
    window.title_override = null;
    window.cancelDrag();
    window.split_view.clear();
    window.tabs.clearRetainingCapacity();
    window.active = 0;

    return .{
        .rect = rect,
        .active = active,
        .title_override = title_override,
        .decorations_override = window.decorations_override,
        .opaque_override = window.opaque_override,
        .tabs = saved,
    };
}

pub fn undo(self: *UndoHistory, app: *App) bool {
    self.tickTimer(app);
    const alloc = app.core_app.alloc;
    while (self.undo_stack.pop()) |item| {
        var entry = item;
        defer entry.deinit(alloc);
        if (self.applyOp(app, &entry, &self.redo_stack)) {
            self.syncTimer(app);
            return true;
        }
    }
    self.syncTimer(app);
    return false;
}

pub fn redo(self: *UndoHistory, app: *App) bool {
    self.tickTimer(app);
    const alloc = app.core_app.alloc;
    while (self.redo_stack.pop()) |item| {
        var entry = item;
        defer entry.deinit(alloc);
        if (self.applyOp(app, &entry, &self.undo_stack)) {
            self.syncTimer(app);
            return true;
        }
    }
    self.syncTimer(app);
    return false;
}

fn applyOp(
    self: *UndoHistory,
    app: *App,
    entry: *Entry,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    _ = self;
    const expires_ms = c.GetTickCount64() + timeoutMs(app);
    return switch (entry.op) {
        .split => |*s| applySplit(app, s, expires_ms, opposite_stack),
        .close_tabs => |*ct| applyCloseTabs(app, ct, expires_ms, opposite_stack),
        .reopen_tabs => |*rt| applyReopenTabs(app, rt, expires_ms, opposite_stack),
        .close_window => |*cw| applyCloseWindow(app, cw, expires_ms, opposite_stack),
        .reopen_window => |*rw| applyReopenWindow(app, rw, expires_ms, opposite_stack),
    };
}

fn applySplit(
    app: *App,
    s: *SplitOp,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    const loc = findTabBySurface(app, s.anchor) orelse return false;
    const win = loc.window;
    const tab = &win.tabs.items[loc.tab_index];

    const cur_count = countLeaves(&tab.tree);
    const target_count = countLeaves(&s.tree);
    if (cur_count != s.expected_count) return false;
    const valid = if (cur_count <= target_count)
        isSubset(&tab.tree, &s.tree)
    else
        isSubset(&s.tree, &tab.tree);
    if (!valid) return false;

    var cur_clone = tab.tree.clone(alloc) catch return false;
    const prev_focused = tab.focused;

    var it_new = s.tree.iterator();
    while (it_new.next()) |node| {
        if (node.view.detached) node.view.attachToWindow(win);
    }

    var it_old = tab.tree.iterator();
    while (it_old.next()) |node| {
        if (s.tree.locate(node.view) == null) {
            node.view.detachFromWindow();
        }
    }

    win.replaceTree(tab, s.tree);
    s.tree = .empty;
    tab.focused = if (tab.tree.locate(s.focused) != null) s.focused else s.anchor;
    win.selectTab(loc.tab_index);
    win.relayout();
    if (win.hwnd) |hwnd| _ = c.SetForegroundWindow(hwnd);

    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{
            .split = .{
                .tree = cur_clone,
                .focused = prev_focused,
                .anchor = s.anchor,
                .expected_count = target_count,
            },
        },
    }) catch {
        cur_clone.deinit();
    };
    return true;
}

fn applyCloseTabs(
    app: *App,
    ct: *CloseTabsOp,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    const target_win = if (windowAlive(app, ct.window))
        ct.window
    else
        (app.activeWindow() orelse return restoreTabsAsWindow(app, &ct.tabs, 0, expires_ms, opposite_stack));

    target_win.tabs.ensureUnusedCapacity(alloc, ct.tabs.len) catch return false;
    const surfaces = alloc.alloc(*Surface, ct.tabs.len) catch return false;
    const prev_active = target_win.activeSurface();

    for (ct.tabs, 0..) |*saved, i| {
        var it = saved.tree.iterator();
        while (it.next()) |node| node.view.attachToWindow(target_win);
        const insert_at = @min(saved.index, target_win.tabs.items.len);
        target_win.tabs.insertAssumeCapacity(insert_at, .{
            .tree = saved.tree,
            .focused = saved.focused,
            .title_override = saved.title_override,
        });
        surfaces[i] = saved.focused;
        saved.tree = .empty;
        saved.title_override = null;
    }
    alloc.free(ct.tabs);
    ct.tabs = &.{};

    const focus_surface = ct.was_active orelse surfaces[0];
    const target_idx = target_win.tabIndex(focus_surface) orelse
        (if (surfaces.len > 0) target_win.tabIndex(surfaces[0]) else null) orelse 0;
    target_win.activateTab(target_idx, prev_active);
    target_win.relayout();
    if (target_win.hwnd) |hwnd| _ = c.SetForegroundWindow(hwnd);

    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{
            .reopen_tabs = .{
                .window = target_win,
                .surfaces = surfaces,
                .was_active = prev_active,
            },
        },
    }) catch {
        alloc.free(surfaces);
    };
    return true;
}

fn applyReopenTabs(
    app: *App,
    rt: *ReopenTabsOp,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    if (!windowAlive(app, rt.window)) return false;
    const win = rt.window;
    var saved_list: std.ArrayList(SavedTab) = .empty;
    defer saved_list.deinit(alloc);

    const cur_active = win.activeSurface();
    for (rt.surfaces) |surf| {
        const idx = win.tabIndex(surf) orelse continue;
        if (win.tabs.items.len <= 1) break;
        const orig_idx = idx + saved_list.items.len;
        const tab = win.tabs.orderedRemove(idx);
        var it = tab.tree.iterator();
        while (it.next()) |node| node.view.detachFromWindow();
        if (idx < win.active) {
            win.active -= 1;
        } else if (idx == win.active and win.tabs.items.len > 0) {
            win.active = @min(idx, win.tabs.items.len - 1);
        }
        saved_list.append(alloc, .{
            .tree = tab.tree,
            .focused = tab.focused,
            .title_override = tab.title_override,
            .index = orig_idx,
        }) catch {
            var st: SavedTab = .{
                .tree = tab.tree,
                .focused = tab.focused,
                .title_override = tab.title_override,
                .index = orig_idx,
            };
            st.deinit(alloc);
        };
    }
    if (saved_list.items.len == 0) return false;

    if (rt.was_active) |wa| {
        if (win.tabIndex(wa)) |idx| win.active = idx;
    }
    win.activateTab(win.active, cur_active);
    win.relayout();

    const saved_slice = saved_list.toOwnedSlice(alloc) catch return true;
    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{
            .close_tabs = .{
                .window = win,
                .tabs = saved_slice,
                .was_active = cur_active,
            },
        },
    }) catch {
        for (saved_slice) |*st| st.deinit(alloc);
        alloc.free(saved_slice);
    };
    return true;
}

fn applyCloseWindow(
    app: *App,
    cw: *CloseWindowOp,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    const win = Window.restoreFromUndo(app, cw) catch return false;
    alloc.free(cw.tabs);
    cw.tabs = &.{};
    cw.title_override = null;

    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{
            .reopen_window = .{ .window = win },
        },
    }) catch {};
    return true;
}

fn applyReopenWindow(
    app: *App,
    rw: *const ReopenWindowOp,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    if (!windowAlive(app, rw.window)) return false;
    const win = rw.window;
    if (!app.canUndoCloseWindow()) return false;
    var cw = captureWindowOp(alloc, win) orelse return false;

    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{ .close_window = cw },
    }) catch {
        cw.deinit(alloc);
    };

    if (win.hwnd) |hwnd| _ = c.DestroyWindow(hwnd);
    return true;
}

fn restoreTabsAsWindow(
    app: *App,
    tabs: *[]SavedTab,
    active: usize,
    expires_ms: u64,
    opposite_stack: *std.ArrayList(Entry),
) bool {
    const alloc = app.core_app.alloc;
    var cw: CloseWindowOp = .{
        .rect = .{},
        .active = active,
        .tabs = tabs.*,
    };
    const win = Window.restoreFromUndo(app, &cw) catch return false;
    alloc.free(tabs.*);
    tabs.* = &.{};
    opposite_stack.append(alloc, .{
        .expires_ms = expires_ms,
        .op = .{ .reopen_window = .{ .window = win } },
    }) catch {};
    return true;
}

const TabLocation = struct {
    window: *Window,
    tab_index: usize,
};

fn findTabBySurface(app: *App, surface: *const Surface) ?TabLocation {
    for (app.windows.items) |win| {
        if (win.tabIndex(surface)) |idx| {
            return .{ .window = win, .tab_index = idx };
        }
    }
    return null;
}

fn windowAlive(app: *const App, target: *const Window) bool {
    for (app.windows.items) |w| {
        if (w == target) return w.hwnd != null;
    }
    return false;
}
