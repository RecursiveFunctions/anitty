const QuickTerminal = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_quick_terminal);

pub const timer_id: c.UINT_PTR = 2;
const frame_interval_ms: c.UINT = 16;

pub const RectPair = struct {
    target: c.RECT,
    hidden: c.RECT,
};

window: ?*Window = null,
visible: bool = false,
animating: bool = false,
anim_in: bool = false,
anim_start_ms: u64 = 0,
anim_duration_ms: u64 = 0,
rects: RectPair = .{ .target = .{}, .hidden = .{} },

pub fn deinit(self: *QuickTerminal, app: *App) void {
    self.stopTimer(app);
    self.window = null;
    self.visible = false;
}

pub fn onWindowDestroyed(self: *QuickTerminal, app: *App, win: *Window) void {
    if (self.window == win) {
        self.stopTimer(app);
        self.window = null;
        self.visible = false;
    }
}

pub fn toggle(self: *QuickTerminal, app: *App) !bool {
    if (self.window) |win| {
        if (win.hwnd != null) {
            if (self.visible) {
                self.hide(app);
            } else {
                self.show(app, win);
            }
            return true;
        }
        self.window = null;
    }

    const win = try Window.createQuickTerminal(app);
    self.window = win;
    self.show(app, win);
    return true;
}

pub fn show(self: *QuickTerminal, app: *App, win: *Window) void {
    const hwnd = win.hwnd orelse return;
    self.stopTimer(app);

    const work = targetWorkArea(&app.config);
    self.rects = computeRects(
        app.config.@"quick-terminal-position",
        app.config.@"quick-terminal-size",
        work,
    );
    self.visible = true;

    const dur_sec = app.config.@"quick-terminal-animation-duration";
    const dur_ms: u64 = if (dur_sec > 0) @intFromFloat(@round(dur_sec * 1000.0)) else 0;
    if (dur_ms > 0) {
        self.animating = true;
        self.anim_in = true;
        self.anim_start_ms = c.GetTickCount64();
        self.anim_duration_ms = dur_ms;
        applyRect(hwnd, self.rects.hidden, true);
        _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
        _ = c.SetForegroundWindow(hwnd);
        if (win.activeSurface()) |s| {
            if (s.hwnd) |shwnd| _ = c.SetFocus(shwnd);
        }
        self.startTimer(app);
    } else {
        applyRect(hwnd, self.rects.target, true);
        _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
        _ = c.SetForegroundWindow(hwnd);
        if (win.activeSurface()) |s| {
            if (s.hwnd) |shwnd| _ = c.SetFocus(shwnd);
        }
    }
}

pub fn hide(self: *QuickTerminal, app: *App) void {
    if (!self.visible) return;
    self.visible = false;
    self.stopTimer(app);
    const win = self.window orelse return;
    const hwnd = win.hwnd orelse return;

    const dur_sec = app.config.@"quick-terminal-animation-duration";
    const dur_ms: u64 = if (dur_sec > 0) @intFromFloat(@round(dur_sec * 1000.0)) else 0;
    if (dur_ms > 0) {
        self.animating = true;
        self.anim_in = false;
        self.anim_start_ms = c.GetTickCount64();
        self.anim_duration_ms = dur_ms;
        self.startTimer(app);
    } else {
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
    }
}

pub fn tickTimer(self: *QuickTerminal, app: *App) void {
    if (!self.animating) {
        self.stopTimer(app);
        return;
    }
    const win = self.window orelse {
        self.stopTimer(app);
        return;
    };
    const hwnd = win.hwnd orelse {
        self.stopTimer(app);
        return;
    };

    const now = c.GetTickCount64();
    const elapsed = now -| self.anim_start_ms;
    if (elapsed >= self.anim_duration_ms or self.anim_duration_ms == 0) {
        self.animating = false;
        self.stopTimer(app);
        if (self.anim_in) {
            applyRect(hwnd, self.rects.target, false);
        } else {
            _ = c.ShowWindow(hwnd, c.SW_HIDE);
        }
        return;
    }

    const raw_t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.anim_duration_ms));
    const eased = easeOutCubic(raw_t);
    const from = if (self.anim_in) self.rects.hidden else self.rects.target;
    const to = if (self.anim_in) self.rects.target else self.rects.hidden;
    const cur = interpolateRect(from, to, eased);
    applyRect(hwnd, cur, false);
    _ = c.DwmFlush();
}

fn startTimer(self: *QuickTerminal, app: *App) void {
    _ = self;
    if (app.msg_hwnd) |hwnd| {
        _ = c.SetTimer(hwnd, timer_id, frame_interval_ms, null);
    }
}

fn stopTimer(self: *QuickTerminal, app: *App) void {
    self.animating = false;
    if (app.msg_hwnd) |hwnd| {
        _ = c.KillTimer(hwnd, timer_id);
    }
}

fn applyRect(hwnd: c.HWND, r: c.RECT, top_most: bool) void {
    _ = c.SetWindowPos(
        hwnd,
        if (top_most) c.HWND_TOPMOST else null,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        if (top_most) c.SWP_NOACTIVATE else c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn targetWorkArea(config: *const configpkg.Config) c.RECT {
    const monitor: ?c.HMONITOR = switch (config.@"quick-terminal-screen") {
        .mouse => mouse: {
            var pt: c.POINT = .{};
            if (c.GetCursorPos(&pt).toBool()) {
                break :mouse c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTONEAREST);
            }
            break :mouse c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY);
        },
        .main, .@"macos-menu-bar" => c.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY),
    };
    if (monitor) |m| {
        var info: c.MONITORINFO = .{};
        if (c.GetMonitorInfoW(m, &info).toBool()) return info.rcWork;
    }
    return .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
}

pub fn computeRects(
    position: configpkg.Config.QuickTerminalPosition,
    size_cfg: configpkg.Config.QuickTerminalSize,
    work: c.RECT,
) RectPair {
    const work_w: u32 = @intCast(@max(1, work.right - work.left));
    const work_h: u32 = @intCast(@max(1, work.bottom - work.top));
    const dims = size_cfg.calculate(position, .{ .width = work_w, .height = work_h });
    const w: i32 = @intCast(@max(120, @min(dims.width, work_w)));
    const h: i32 = @intCast(@max(80, @min(dims.height, work_h)));
    const cx = work.left + @divTrunc(@as(i32, @intCast(work_w)) - w, 2);
    const cy = work.top + @divTrunc(@as(i32, @intCast(work_h)) - h, 2);

    return switch (position) {
        .top => .{
            .target = .{ .left = cx, .top = work.top, .right = cx + w, .bottom = work.top + h },
            .hidden = .{ .left = cx, .top = work.top - h, .right = cx + w, .bottom = work.top },
        },
        .bottom => .{
            .target = .{ .left = cx, .top = work.bottom - h, .right = cx + w, .bottom = work.bottom },
            .hidden = .{ .left = cx, .top = work.bottom, .right = cx + w, .bottom = work.bottom + h },
        },
        .left => .{
            .target = .{ .left = work.left, .top = cy, .right = work.left + w, .bottom = cy + h },
            .hidden = .{ .left = work.left - w, .top = cy, .right = work.left, .bottom = cy + h },
        },
        .right => .{
            .target = .{ .left = work.right - w, .top = cy, .right = work.right, .bottom = cy + h },
            .hidden = .{ .left = work.right, .top = cy, .right = work.right + w, .bottom = cy + h },
        },
        .center => .{
            .target = .{ .left = cx, .top = cy, .right = cx + w, .bottom = cy + h },
            .hidden = .{ .left = cx, .top = cy - 24, .right = cx + w, .bottom = cy + h - 24 },
        },
    };
}

pub fn easeOutCubic(t: f32) f32 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    const inv = 1.0 - clamped;
    return 1.0 - inv * inv * inv;
}

pub fn interpolateRect(from: c.RECT, to: c.RECT, t: f32) c.RECT {
    const lerp = struct {
        fn call(a: i32, b: i32, f: f32) i32 {
            return a + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(b - a)) * f)));
        }
    }.call;
    return .{
        .left = lerp(from.left, to.left, t),
        .top = lerp(from.top, to.top, t),
        .right = lerp(from.right, to.right, t),
        .bottom = lerp(from.bottom, to.bottom, t),
    };
}

test "QuickTerminal computeRects and interpolateRect" {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    const pair = computeRects(.top, .{}, work);
    try testing.expectEqual(@as(i32, 0), pair.target.top);
    try testing.expectEqual(@as(i32, 400), pair.target.bottom);
    try testing.expectEqual(@as(i32, -400), pair.hidden.top);
    const mid = interpolateRect(pair.hidden, pair.target, 0.5);
    try testing.expectEqual(@as(i32, -200), mid.top);
}
