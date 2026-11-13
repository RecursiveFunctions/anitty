const InspectorWindow = @This();

const std = @import("std");
const cimgui = @import("dcimgui");
const gl = @import("opengl");
const Inspector = @import("../../inspector/Inspector.zig");
const wgl = @import("../../renderer/opengl/wgl.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const key = @import("key.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_inspector);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const class_name = L("GhosttyInspector");
const refresh_timer_id: c.UINT_PTR = 1;
const refresh_interval_ms: c.UINT = 100;

surface: *Surface,
hwnd: ?c.HWND = null,
wgl_ctx: ?wgl.Context = null,
ig_context: ?*cimgui.c.ImGuiContext = null,
last_tick_ms: u64 = 0,
width: u32 = 840,
height: u32 = 560,
key_utf8: [32]u8 = undefined,

pub fn toggle(surface: *Surface, mode: @import("../../apprt.zig").action.Inspector) bool {
    return switch (mode) {
        .toggle => if (surface.inspector_window != null) hide(surface) else show(surface),
        .show => show(surface),
        .hide => hide(surface),
    };
}

pub fn show(surface: *Surface) bool {
    if (surface.inspector_window) |win| {
        if (win.hwnd) |hwnd| {
            _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
            _ = c.SetForegroundWindow(hwnd);
            win.queueRender();
            return true;
        }
        win.destroy();
    }

    const win = create(surface) catch |err| {
        log.warn("failed to create inspector window err={}", .{err});
        return false;
    };
    surface.inspector_window = win;
    return true;
}

pub fn hide(surface: *Surface) bool {
    if (surface.inspector_window) |win| {
        win.destroy();
        return true;
    }
    return false;
}

fn create(surface: *Surface) !*InspectorWindow {
    const alloc = surface.app.core_app.alloc;
    const self = try alloc.create(InspectorWindow);
    self.* = .{
        .surface = surface,
        .last_tick_ms = c.GetTickCount64(),
    };
    errdefer alloc.destroy(self);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_APPWINDOW,
        class_name,
        L("Ghostty Terminal Inspector"),
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        840,
        560,
        null,
        null,
        surface.app.instance,
        self,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);

    const dark: c.BOOL = if (surface.app.chrome.dark) .TRUE else .FALSE;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));

    self.wgl_ctx = try wgl.Context.init(hwnd, true);
    errdefer if (self.wgl_ctx) |*ctx| ctx.deinit();

    try self.wgl_ctx.?.makeCurrent();
    defer wgl.Context.releaseCurrent();
    _ = try gl.glad.load(&wgl.getProcAddress);

    self.ig_context = cimgui.c.ImGui_CreateContext(null) orelse return error.ImGuiContextFailed;
    errdefer cimgui.c.ImGui_DestroyContext(self.ig_context);
    cimgui.c.ImGui_SetCurrentContext(self.ig_context);

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.BackendPlatformName = "ghostty_win32";

    if (!cimgui.ImGui_ImplOpenGL3_Init(null)) return error.ImGuiOpenGLInitFailed;
    errdefer cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();

    Inspector.setup();
    try surface.core_surface.activateInspector();

    self.updateMetrics(hwnd);
    _ = c.SetTimer(hwnd, refresh_timer_id, refresh_interval_ms, null);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(hwnd);
    return self;
}

pub fn destroy(self: *InspectorWindow) void {
    const surface = self.surface;
    if (surface.inspector_window == self) {
        surface.inspector_window = null;
    }
    surface.core_surface.deactivateInspector();

    if (self.hwnd) |hwnd| {
        _ = c.KillTimer(hwnd, refresh_timer_id);
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        if (self.wgl_ctx) |*ctx| {
            if (self.ig_context) |ig| {
                if (ctx.makeCurrent()) |_| {
                    cimgui.c.ImGui_SetCurrentContext(ig);
                    cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
                    cimgui.c.ImGui_DestroyContext(ig);
                    wgl.Context.releaseCurrent();
                } else |_| {}
                self.ig_context = null;
            }
            ctx.deinit();
            self.wgl_ctx = null;
        }
        self.hwnd = null;
        _ = c.DestroyWindow(hwnd);
    }
    surface.app.core_app.alloc.destroy(self);
}

pub fn queueRender(self: *InspectorWindow) void {
    if (self.hwnd) |hwnd| _ = c.InvalidateRect(hwnd, null, .FALSE);
}

fn updateMetrics(self: *InspectorWindow, hwnd: c.HWND) void {
    const ig = self.ig_context orelse return;
    cimgui.c.ImGui_SetCurrentContext(ig);
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    self.width = @intCast(@max(1, r.right - r.left));
    self.height = @intCast(@max(1, r.bottom - r.top));

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.DisplaySize = .{
        .x = @floatFromInt(self.width),
        .y = @floatFromInt(self.height),
    };
    io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

    const dpi = c.GetDpiForWindow(hwnd);
    const scale = @max(1.0, @as(f32, @floatFromInt(dpi)) / 96.0);
    var style: cimgui.c.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
    const active_style = cimgui.c.ImGui_GetStyle();
    active_style.* = style;
}

fn renderFrame(self: *InspectorWindow) void {
    const ctx = &(self.wgl_ctx orelse return);
    const ig = self.ig_context orelse return;
    if (self.width == 0 or self.height == 0) return;

    ctx.makeCurrent() catch return;
    defer wgl.Context.releaseCurrent();

    cimgui.c.ImGui_SetCurrentContext(ig);
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    const now = c.GetTickCount64();
    const dt_ms = now -| self.last_tick_ms;
    self.last_tick_ms = now;
    io.DeltaTime = @max(0.001, @as(f32, @floatFromInt(dt_ms)) / 1000.0);

    gl.viewport(0, 0, @intCast(self.width), @intCast(self.height)) catch {};
    if (gl.glad.context.ClearColor) |clearColor| clearColor(0.11, 0.11, 0.13, 1.0);
    if (gl.glad.context.Clear) |clear| clear(gl.c.GL_COLOR_BUFFER_BIT);

    if (self.surface.core_surface.inspector) |inspector| {
        for (0..2) |_| {
            cimgui.ImGui_ImplOpenGL3_NewFrame();
            cimgui.c.ImGui_NewFrame();
            inspector.render(&self.surface.core_surface);
            cimgui.c.ImGui_Render();
        }
        cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());
    }

    ctx.swapBuffers(self.width, self.height) catch {};
}

fn onKey(self: *InspectorWindow, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) void {
    const ig = self.ig_context orelse return;
    cimgui.c.ImGui_SetCurrentContext(ig);
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

    if (key.translate(msg, wparam, lparam, c.GetKeyboardLayout(0), &self.key_utf8)) |ev| {
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, ev.mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, ev.mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, ev.mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, ev.mods.super);
        if (ev.key.imguiKey()) |im_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(io, im_key, ev.action != .release);
        }
    }
    self.queueRender();
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *InspectorWindow = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *InspectorWindow = @ptrFromInt(ptr);

    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = .{};
            _ = c.BeginPaint(hwnd, &ps);
            _ = c.EndPaint(hwnd, &ps);
            self.renderFrame();
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_SIZE => {
            if (wparam != c.SIZE_MINIMIZED) {
                self.updateMetrics(hwnd);
                self.renderFrame();
            }
            return 0;
        },
        c.WM_DPICHANGED => {
            const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            self.updateMetrics(hwnd);
            self.queueRender();
            return 0;
        },
        c.WM_TIMER => if (wparam == refresh_timer_id) {
            self.queueRender();
            return 0;
        },
        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            if (self.ig_context) |ig| {
                cimgui.c.ImGui_SetCurrentContext(ig);
                const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                cimgui.c.ImGuiIO_AddFocusEvent(io, msg == c.WM_SETFOCUS);
                self.queueRender();
            }
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (self.ig_context) |ig| {
                cimgui.c.ImGui_SetCurrentContext(ig);
                const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                const x: i16 = @bitCast(c.loword(lparam));
                const y: i16 = @bitCast(c.hiword(lparam));
                cimgui.c.ImGuiIO_AddMousePosEvent(io, @floatFromInt(x), @floatFromInt(y));
                self.queueRender();
            }
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_RBUTTONDOWN, c.WM_RBUTTONUP, c.WM_MBUTTONDOWN, c.WM_MBUTTONUP => {
            if (self.ig_context) |ig| {
                cimgui.c.ImGui_SetCurrentContext(ig);
                const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                const button: c_int = switch (msg) {
                    c.WM_LBUTTONDOWN, c.WM_LBUTTONUP => cimgui.c.ImGuiMouseButton_Left,
                    c.WM_RBUTTONDOWN, c.WM_RBUTTONUP => cimgui.c.ImGuiMouseButton_Right,
                    else => cimgui.c.ImGuiMouseButton_Middle,
                };
                const down = msg == c.WM_LBUTTONDOWN or msg == c.WM_RBUTTONDOWN or msg == c.WM_MBUTTONDOWN;
                if (down) _ = c.SetCapture(hwnd) else if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
                cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, down);
                self.queueRender();
            }
            return 0;
        },
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            if (self.ig_context) |ig| {
                cimgui.c.ImGui_SetCurrentContext(ig);
                const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
                const steps = @as(f32, @floatFromInt(delta)) / @as(f32, @floatCast(c.WHEEL_DELTA));
                if (msg == c.WM_MOUSEHWHEEL) {
                    cimgui.c.ImGuiIO_AddMouseWheelEvent(io, -steps, 0);
                } else {
                    cimgui.c.ImGuiIO_AddMouseWheelEvent(io, 0, steps);
                }
                self.queueRender();
            }
            return 0;
        },
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            self.onKey(msg, wparam, lparam);
            return 0;
        },
        c.WM_CHAR => {
            if (self.ig_context) |ig| {
                cimgui.c.ImGui_SetCurrentContext(ig);
                const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                if (wparam >= 0x20) {
                    cimgui.c.ImGuiIO_AddInputCharacterUTF16(io, @truncate(wparam));
                    self.queueRender();
                }
            }
            return 0;
        },
        c.WM_CLOSE => {
            self.destroy();
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
