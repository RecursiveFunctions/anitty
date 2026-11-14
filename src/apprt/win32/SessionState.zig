const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const App = @import("App.zig");
const SplitView = @import("SplitView.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_session);

pub const state_filename = "window-state.json";
pub const current_version: u32 = 1;

pub const SavedSession = struct {
    version: u32 = current_version,
    forced: bool = false,
    windows: []const SavedWindow = &.{},
};

pub const SavedWindow = struct {
    x: i32 = c.CW_USEDEFAULT,
    y: i32 = c.CW_USEDEFAULT,
    width: i32 = 800,
    height: i32 = 600,
    maximized: bool = false,
    fullscreen: bool = false,
    decorations_override: ?bool = null,
    opaque_override: bool = false,
    title_override: ?[]const u8 = null,
    active_tab: usize = 0,
    tabs: []const SavedTab = &.{},
};

pub const SavedTab = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: usize = 0,
    zoomed_node: ?u16 = null,
    nodes: []const SavedNode = &.{},
};

pub const SavedNode = struct {
    kind: enum { leaf, split } = .leaf,
    pwd: ?[]const u8 = null,
    title_override: ?[]const u8 = null,
    layout: SplitView.Layout = .horizontal,
    ratio: f32 = 0.5,
    left: u16 = 0,
    right: u16 = 0,
};

pub fn shouldSave(mode: configpkg.Config.WindowSaveState, forced: bool) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .default => forced,
    };
}

pub fn stateFilePath(alloc: Allocator) ![]u8 {
    const io = global.io();
    var env = try global.environMap();
    defer env.deinit();
    const state_dir = try internal_os.xdg.state(io, alloc, &env, .{ .subdir = "ghostty" });
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &.{ state_dir, state_filename });
}

pub fn clearSavedState(alloc: Allocator) void {
    const path = stateFilePath(alloc) catch return;
    defer alloc.free(path);
    std.Io.Dir.deleteFileAbsolute(global.io(), path) catch {};
}

pub fn save(app: *App, forced: bool) void {
    const alloc = app.core_app.alloc;
    if (!shouldSave(app.config.@"window-save-state", forced)) {
        clearSavedState(alloc);
        return;
    }
    saveImpl(app, forced) catch |err| {
        log.warn("failed to save window state err={}", .{err});
    };
}

fn saveImpl(app: *App, forced: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(app.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var windows: std.ArrayList(SavedWindow) = .empty;
    for (app.windows.items) |win| {
        if (win.is_quick_terminal or win.tabs.items.len == 0) continue;
        const hwnd = win.hwnd orelse continue;

        var rect: c.RECT = .{};
        _ = c.GetWindowRect(hwnd, &rect);
        var wp: c.WINDOWPLACEMENT = .{};
        if (win.fullscreen_saved) |fs| {
            rect = fs.placement.rcNormalPosition;
        } else if (c.GetWindowPlacement(hwnd, &wp).toBool() and
            (c.IsZoomed(hwnd).toBool() or c.IsIconic(hwnd).toBool()))
        {
            rect = wp.rcNormalPosition;
        }

        var tabs: std.ArrayList(SavedTab) = .empty;
        for (win.tabs.items) |*tab| {
            if (tab.tree.isEmpty()) continue;
            var nodes: std.ArrayList(SavedNode) = .empty;
            var focused_leaf: usize = 0;
            for (tab.tree.nodes, 0..) |node, idx| {
                switch (node) {
                    .leaf => |s| {
                        if (s == tab.focused) focused_leaf = idx;
                        const pwd: ?[]const u8 = if (s.getPwd()) |p|
                            p
                        else
                            s.core().pwd(alloc) catch null;
                        try nodes.append(alloc, .{
                            .kind = .leaf,
                            .pwd = pwd,
                            .title_override = s.title_override,
                        });
                    },
                    .split => |sp| {
                        try nodes.append(alloc, .{
                            .kind = .split,
                            .layout = sp.layout,
                            .ratio = @floatCast(sp.ratio),
                            .left = @backingInt(sp.left),
                            .right = @backingInt(sp.right),
                        });
                    },
                }
            }
            try tabs.append(alloc, .{
                .title_override = tab.title_override,
                .focused_leaf = focused_leaf,
                .zoomed_node = if (tab.tree.zoomed) |z| @backingInt(z) else null,
                .nodes = try nodes.toOwnedSlice(alloc),
            });
        }
        if (tabs.items.len == 0) continue;

        try windows.append(alloc, .{
            .x = rect.left,
            .y = rect.top,
            .width = @max(200, rect.right - rect.left),
            .height = @max(150, rect.bottom - rect.top),
            .maximized = c.IsZoomed(hwnd).toBool(),
            .fullscreen = win.fullscreen_saved != null,
            .decorations_override = win.decorations_override,
            .opaque_override = win.opaque_override,
            .title_override = win.title_override,
            .active_tab = @min(win.active, tabs.items.len - 1),
            .tabs = try tabs.toOwnedSlice(alloc),
        });
    }

    if (windows.items.len == 0) {
        clearSavedState(app.core_app.alloc);
        return;
    }

    const session: SavedSession = .{
        .version = current_version,
        .forced = forced,
        .windows = try windows.toOwnedSlice(alloc),
    };

    const json = try serializeJson(alloc, session);
    const path = try stateFilePath(alloc);
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const io = global.io();
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(json);
    try writer.interface.flush();
}

pub fn serializeJson(alloc: Allocator, session: SavedSession) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.write(session);
    return try out.toOwnedSlice();
}

pub fn parseJson(alloc: Allocator, bytes: []const u8) !std.json.Parsed(SavedSession) {
    return try std.json.parseFromSlice(SavedSession, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn restore(app: *App) bool {
    const alloc = app.core_app.alloc;
    if (app.config.@"window-save-state" == .never) {
        clearSavedState(alloc);
        return false;
    }
    return restoreImpl(app) catch |err| {
        log.debug("no saved window state restored err={}", .{err});
        return false;
    };
}

fn restoreImpl(app: *App) !bool {
    const gpa = app.core_app.alloc;
    const io = global.io();
    const path = try stateFilePath(gpa);
    defer gpa.free(path);

    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const bytes = try file_reader.interface.allocRemaining(gpa, .limited(2 * 1024 * 1024));
    defer gpa.free(bytes);

    // Consume the state file so crashes or a one-time forced save do not loop.
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var parsed = try parseJson(gpa, bytes);
    defer parsed.deinit();
    const session = parsed.value;
    if (session.version != current_version or session.windows.len == 0) return false;
    if (app.config.@"window-save-state" == .default and !session.forced) return false;

    var restored_any = false;
    for (session.windows) |sw| {
        if (sw.tabs.len == 0) continue;
        if (Window.restoreFromSession(app, sw)) |_| {
            restored_any = true;
        } else |err| {
            log.warn("failed to restore window from session err={}", .{err});
        }
    }
    return restored_any;
}

test "SessionState JSON round trip and shouldSave" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(!shouldSave(.never, false));
    try testing.expect(!shouldSave(.never, true));
    try testing.expect(!shouldSave(.default, false));
    try testing.expect(shouldSave(.default, true));
    try testing.expect(shouldSave(.always, false));
    try testing.expect(shouldSave(.always, true));

    const nodes = [_]SavedNode{
        .{ .kind = .split, .layout = .horizontal, .ratio = 0.6, .left = 1, .right = 2 },
        .{ .kind = .leaf, .pwd = "C:\\Users\\Ray", .title_override = "Shell 1" },
        .{ .kind = .leaf, .pwd = "C:\\Projects", .title_override = null },
    };
    const tabs = [_]SavedTab{.{
        .title_override = "Dev",
        .focused_leaf = 2,
        .zoomed_node = null,
        .nodes = &nodes,
    }};
    const wins = [_]SavedWindow{.{
        .x = 120,
        .y = 80,
        .width = 1280,
        .height = 800,
        .maximized = false,
        .fullscreen = false,
        .decorations_override = true,
        .opaque_override = false,
        .title_override = "Main Window",
        .active_tab = 0,
        .tabs = &tabs,
    }};
    const session: SavedSession = .{
        .version = current_version,
        .forced = true,
        .windows = &wins,
    };

    const json = try serializeJson(alloc, session);
    defer alloc.free(json);

    var parsed = try parseJson(alloc, json);
    defer parsed.deinit();

    try testing.expectEqual(current_version, parsed.value.version);
    try testing.expect(parsed.value.forced);
    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    const rw = parsed.value.windows[0];
    try testing.expectEqual(@as(i32, 120), rw.x);
    try testing.expectEqual(@as(i32, 1280), rw.width);
    try testing.expectEqualStrings("Main Window", rw.title_override.?);
    try testing.expectEqual(@as(usize, 1), rw.tabs.len);
    const rt = rw.tabs[0];
    try testing.expectEqualStrings("Dev", rt.title_override.?);
    try testing.expectEqual(@as(usize, 2), rt.focused_leaf);
    try testing.expectEqual(@as(usize, 3), rt.nodes.len);
    try testing.expectEqualStrings("C:\\Users\\Ray", rt.nodes[1].pwd.?);
}
