const Surface = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const clipboard = @import("clipboard.zig");
const key = @import("key.zig");
const dialogs = @import("dialogs.zig");
const ime = @import("ime.zig");
const SearchOverlay = @import("SearchOverlay.zig");
const SurfaceOverlay = @import("SurfaceOverlay.zig");
const TabBar = @import("TabBar.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const DropTarget = @import("DropTarget.zig");
const i18n = @import("../../os/main.zig").i18n;

const log = std.log.scoped(.win32);

core_surface: CoreSurface,
app: *App,
window: *Window,
hwnd: ?c.HWND = null,
ref_count: usize = 1,
detached: bool = false,
initialized: bool = false,
size: apprt.SurfaceSize = .{ .width = 800, .height = 600 },
content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
title: ?[:0]const u8 = null,
title_override: ?[:0]const u8 = null,
pwd_path: ?[:0]const u8 = null,
hover_url: ?[:0]const u8 = null,
dynamic_bg: ?configpkg.Config.Color = null,
dynamic_fg: ?configpkg.Config.Color = null,
bell_ringing: bool = false,
cell_size: apprt.action.CellSize = .{ .width = 0, .height = 0 },
search_overlay: SearchOverlay = .{},
overlay: SurfaceOverlay = .{},
inspector_window: ?*InspectorWindow = null,
key_utf8: [32]u8 = undefined,
sys_char_passthrough: bool = false,
dead_key_pending: bool = false,
preedit_utf8: [8]u8 = undefined,
key_down_pending: bool = false,
char_decoder: key.CharDecoder = .{},
ime_state: ime.State = .{},
focused: bool = false,
secure_input: bool = false,
mouse_shape: terminal.MouseShape = .text,
cursor_handle: ?c.HCURSOR = null,
mouse_mods: input.Mods = .{},
mouse_hidden: bool = false,
mouse_tracking: bool = false,
mouse_buttons: u16 = 0,
drop_target: ?*DropTarget = null,
is_cmd_shell: bool = false,

const WM_GHOSTTY_FOCUS = c.WM_APP + 0x50;

pub fn create(
    window: *Window,
    rect: c.RECT,
    context: apprt.surface.NewSurfaceContext,
    parent_surface: ?*CoreSurface,
) !*Surface {
    return createWithWorkingDirectory(window, rect, context, parent_surface, null);
}

pub fn createWithWorkingDirectory(
    window: *Window,
    rect: c.RECT,
    context: apprt.surface.NewSurfaceContext,
    parent_surface: ?*CoreSurface,
    pwd_override: ?[]const u8,
) !*Surface {
    const app = window.app;
    const alloc = app.core_app.alloc;
    const parent = window.hwnd orelse return error.WindowNotCreated;

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);
    self.* = .{
        .core_surface = undefined,
        .app = app,
        .window = window,
    };

    const hwnd = c.CreateWindowExW(
        0,
        App.surface_class_name,
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent,
        null,
        app.instance,
        self,
    ) orelse return error.CreateWindowFailed;
    errdefer {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }

    try self.overlay.create(hwnd, app.instance);
    try self.search_overlay.create(hwnd, app.instance);

    self.updateSize();
    self.updateContentScale();
    log.debug("surface hwnd created size={}x{} scale={d}", .{
        self.size.width,
        self.size.height,
        self.content_scale.x,
    });

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);
    log.debug("surface added to core app", .{});

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    if (pwd_override) |pwd| {
        if (pwd.len > 0) {
            config.@"working-directory" = .{ .path = try config._arena.?.allocator().dupe(u8, pwd) };
        }
    } else if (parent_surface) |p| {
        if (apprt.surface.shouldInheritWorkingDirectory(context, &app.config)) {
            if (try p.pwd(config._arena.?.allocator())) |pwd| config.@"working-directory" = .{ .path = pwd };
        }
    }
    try app.ipc.applyOverrides(&config);
    self.is_cmd_shell = isCmdCommand(config.command);

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    self.initialized = true;
    self.core_surface.colorSchemeCallback(app.color_scheme) catch |err| {
        log.warn("error in initial color scheme callback err={}", .{err});
    };
    self.drop_target = DropTarget.register(alloc, self);
    log.debug("core surface initialized", .{});

    self.updateSize();
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };
    const grid = self.core_surface.size.grid();
    self.overlay.notifyGridResize(grid.columns, grid.rows);

    return self;
}

pub fn deinit(self: *Surface) void {
    if (!self.initialized) return;
    self.initialized = false;
    self.app.core_app.deleteSurface(self);
    self.core_surface.deinit();
    log.debug("core surface deinitialized", .{});
}

pub fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    log.debug("surface destroy", .{});

    if (self.inspector_window) |insp| insp.destroy();
    if (self.drop_target) |dt| {
        self.drop_target = null;
        dt.revoke(self.hwnd);
    }
    self.deinit();

    if (self.hwnd) |hwnd| {
        self.hwnd = null;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(hwnd);
    }

    self.overlay.deinit(alloc);
    if (self.title) |v| alloc.free(v);
    if (self.title_override) |v| alloc.free(v);
    if (self.pwd_path) |v| alloc.free(v);
    if (self.hover_url) |v| alloc.free(v);
    alloc.destroy(self);
}

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn ref(self: *Surface) *Surface {
    self.ref_count += 1;
    return self;
}

pub fn unref(self: *Surface) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count -= 1;
    if (self.ref_count == 0) self.destroy();
}

pub fn detachFromWindow(self: *Surface) void {
    const prev_window = self.window;
    self.detached = true;
    if (self.inspector_window) |insp| insp.destroy();
    self.setVisible(false);
    if (self.hwnd) |hwnd| {
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
        if (self.app.msg_hwnd) |msg_hwnd| {
            _ = c.SetParent(hwnd, msg_hwnd);
        }
    }
    prev_window.syncDisplayAffinity();
}

pub fn attachToWindow(self: *Surface, target: *Window) void {
    const target_hwnd = target.hwnd orelse return;
    self.detached = false;
    self.window = target;
    if (self.hwnd) |hwnd| {
        _ = c.SetParent(hwnd, target_hwnd);
    }
    const dpi = c.GetDpiForWindow(target_hwnd);
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    if (self.content_scale.x != scale) self.dpiChanged(dpi);
    target.syncDisplayAffinity();
    self.refresh();
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

pub fn close(self: *Surface, process_active: bool) void {
    if (self.detached) return;
    if (process_active and !Window.confirmClose(self.window.hwnd)) return;
    self.window.closeSurface(self);
}

pub fn present(self: *Surface) void {
    if (self.detached) return;
    self.window.selectSurface(self);
    if (self.window.hwnd) |hwnd| _ = c.SetForegroundWindow(hwnd);
    if (self.hwnd) |hwnd| _ = c.SetFocus(hwnd);
}

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, title, 0);
    if (self.title) |v| alloc.free(v);
    self.title = copy;
    if (!self.detached) self.window.surfaceTitleChanged(self);
}

pub fn palette(self: *const Surface) TabBar.Palette {
    return .initWithDynamic(&self.app.config, self.dynamic_bg, self.dynamic_fg);
}

pub fn setColorChange(self: *Surface, change: apprt.action.ColorChange) void {
    const color: configpkg.Config.Color = .{
        .r = change.r,
        .g = change.g,
        .b = change.b,
    };
    switch (change.kind) {
        .background => self.dynamic_bg = color,
        .foreground => self.dynamic_fg = color,
        else => return,
    }
    self.search_overlay.invalidate();
    self.overlay.invalidate();
    if (!self.detached) self.window.surfaceColorChanged(self);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getEffectiveTitle(self: *Surface) ?[:0]const u8 {
    return self.title_override orelse self.title;
}

pub fn setTitleOverride(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (title.len == 0) null else try alloc.dupeSentinel(u8, title, 0);
    if (self.title_override) |v| alloc.free(v);
    self.title_override = copy;
    if (!self.detached) self.window.surfaceTitleChanged(self);
}

pub fn copyTitleToClipboard(self: *Surface) bool {
    const title = self.getEffectiveTitle() orelse return false;
    if (title.len == 0) return false;
    clipboard.writeText(self.app.core_app.alloc, self.hwnd, title) catch |err| {
        log.warn("error copying title to clipboard err={}", .{err});
        return false;
    };
    return true;
}

pub fn setPwd(self: *Surface, pwd: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (pwd.len == 0) null else try alloc.dupeSentinel(u8, pwd, 0);
    if (self.pwd_path) |v| alloc.free(v);
    self.pwd_path = copy;
}

pub fn getPwd(self: *const Surface) ?[:0]const u8 {
    return self.pwd_path;
}

pub fn setMouseOverLink(self: *Surface, url: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (url.len == 0) null else try alloc.dupeSentinel(u8, url, 0);
    if (self.hover_url) |v| alloc.free(v);
    self.hover_url = copy;
    self.overlay.refreshPill();
}

pub fn setCellSize(self: *Surface, width: u32, height: u32) void {
    self.cell_size = .{ .width = width, .height = height };
}

pub fn setBellRinging(self: *Surface, ringing: bool) void {
    if (self.bell_ringing == ringing) return;
    self.bell_ringing = ringing;
    if (!self.detached) self.window.surfaceBellChanged(self);
}

pub fn setSecureInput(self: *Surface, mode: apprt.action.SecureInput) void {
    const next = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !self.secure_input,
    };
    if (self.secure_input == next) return;
    self.secure_input = next;
    self.overlay.setSecureInput(next);
    if (!self.detached) self.window.syncDisplayAffinity();
    if (self.initialized) {
        self.core_surface.renderer_state.mutex.lockUncancelable(global.io());
        self.core_surface.io.terminal.flags.password_input = next;
        self.core_surface.renderer_state.mutex.unlock(global.io());
        self.refresh();
    }
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

fn updateSize(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    self.size = .{
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn updateContentScale(self: *Surface) void {
    const hwnd = self.hwnd orelse return;
    self.setDpi(c.GetDpiForWindow(hwnd));
}

fn setDpi(self: *Surface, dpi: c.UINT) void {
    if (dpi == 0) return;
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    self.content_scale = .{ .x = scale, .y = scale };
}

pub fn dpiChanged(self: *Surface, dpi: c.UINT) void {
    self.setDpi(dpi);
    if (!self.initialized) return;
    self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
        log.warn("error in content scale callback err={}", .{err});
    };
}

pub fn setVisible(self: *Surface, visible: bool) void {
    if (!self.initialized) return;
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.warn("error in occlusion callback err={}", .{err});
    };
}

pub fn refresh(self: *Surface) void {
    if (!self.initialized) return;
    self.core_surface.refreshCallback() catch |err| {
        log.warn("error in refresh callback err={}", .{err});
    };
}

pub fn presentFresh(self: *Surface, timeout_ms: u32) bool {
    if (!self.initialized) return true;
    self.core_surface.renderer.api.provider.presented_size.store(0, .release);
    self.refresh();
    return self.waitPresented(timeout_ms);
}

pub fn waitPresented(self: *Surface, timeout_ms: u32) bool {
    if (!self.initialized or !self.core_surface.visible) return true;
    const hwnd = self.hwnd orelse return true;
    if (!c.IsWindowVisible(hwnd).toBool()) return true;
    if (self.size.width == 0 or self.size.height == 0) return true;
    return self.core_surface.renderer.api.provider.waitPresented(
        self.size.width,
        self.size.height,
        timeout_ms,
    );
}

fn focusChanged(self: *Surface, focused: bool) void {
    self.focused = focused;
    if (focused) {
        self.setBellRinging(false);
    } else {
        self.char_decoder = .{};
        self.ime_state.resetComposition(self, self.hwnd);
        if (self.dead_key_pending) {
            self.dead_key_pending = false;
            if (self.initialized) {
                self.core_surface.preeditCallback(null) catch |err| {
                    log.warn("error in preedit callback err={}", .{err});
                };
            }
        }
        key.drainDeadKeyState(c.GetKeyboardLayout(0));
    }
    const hwnd = self.hwnd orelse return;
    _ = c.PostMessageW(hwnd, WM_GHOSTTY_FOCUS, 0, 0);
}

fn applyFocus(self: *Surface) void {
    if (!self.initialized) return;
    self.core_surface.focusCallback(self.focused) catch |err| {
        log.warn("error in focus callback err={}", .{err});
    };
    self.app.core_app.focusEvent(self.focused);
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    if (self.mouse_shape == shape and self.cursor_handle != null) return;
    self.mouse_shape = shape;
    self.cursor_handle = loadCursorForShape(shape);
    if (self.mouse_tracking) _ = c.SetCursor(self.currentCursor());
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    const hidden = !visible;
    if (self.mouse_hidden == hidden) return;
    self.mouse_hidden = hidden;
    if (self.mouse_tracking) _ = c.SetCursor(self.currentCursor());
}

fn loadCursorForShape(shape: terminal.MouseShape) ?c.HCURSOR {
    return c.LoadCursorW(null, switch (shape) {
        .default, .context_menu, .alias, .copy, .zoom_in, .zoom_out => c.IDC_ARROW,
        .help => c.IDC_HELP,
        .pointer => c.IDC_HAND,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .cell, .crosshair => c.IDC_CROSS,
        .text, .vertical_text => c.IDC_IBEAM,
        .move, .grab, .grabbing, .all_scroll => c.IDC_SIZEALL,
        .no_drop, .not_allowed => c.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => c.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => c.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => c.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => c.IDC_SIZENWSE,
    });
}

fn currentCursor(self: *Surface) ?c.HCURSOR {
    if (self.mouse_hidden) return null;
    if (self.cursor_handle) |h| return h;
    const h = loadCursorForShape(self.mouse_shape);
    self.cursor_handle = h;
    return h;
}

fn mouseMods(wparam: c.WPARAM) input.Mods {
    return .{
        .shift = wparam & c.MK_SHIFT != 0,
        .ctrl = wparam & c.MK_CONTROL != 0,
        .alt = c.GetKeyState(c.VK_MENU) < 0,
        .super = c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0,
    };
}

fn trackMouseLeave(self: *Surface) void {
    c.trackMouseLeave(self.hwnd, &self.mouse_tracking);
}

fn mouseMove(self: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) void {
    self.trackMouseLeave();
    const x = c.xFromLparam(lparam);
    const y = c.yFromLparam(lparam);
    const pos: apprt.CursorPos = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    const mods = mouseMods(wparam);
    if (pos.x == self.cursor_pos.x and pos.y == self.cursor_pos.y and mods.equal(self.mouse_mods)) return;
    self.cursor_pos = pos;
    self.mouse_mods = mods;
    if (!self.focused and !self.detached and self.app.config.@"focus-follows-mouse") {
        if (self.window.hwnd) |win_hwnd| {
            if (c.GetForegroundWindow() == win_hwnd) {
                self.window.selectSurface(self);
                if (self.hwnd) |h| _ = c.SetFocus(h);
            }
        }
    }
    if (self.overlay.pill_len > 0) self.overlay.refreshPill();
    if (!self.initialized) return;
    self.core_surface.cursorPosCallback(pos, mods) catch |err| {
        log.warn("error in cursor pos callback err={}", .{err});
    };
}

fn mouseLeave(self: *Surface) void {
    self.mouse_tracking = false;
    if (self.mouse_buttons != 0) return;
    self.cursor_pos = .{ .x = -1, .y = -1 };
    if (!self.initialized) return;
    self.core_surface.cursorPosCallback(self.cursor_pos, null) catch |err| {
        log.warn("error in cursor pos callback err={}", .{err});
    };
}

fn mouseButton(
    self: *Surface,
    state: input.MouseButtonState,
    button: input.MouseButton,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) bool {
    const hwnd = self.hwnd orelse return false;
    if (state == .press and (button == .left or button == .right)) _ = c.SetFocus(hwnd);
    self.mouseMove(wparam, lparam);

    const bit = @as(u16, 1) << @intCast(@backingInt(button));
    switch (state) {
        .press => {
            if (self.mouse_buttons == 0) _ = c.SetCapture(hwnd);
            self.mouse_buttons |= bit;
        },
        .release => {
            self.mouse_buttons &= ~bit;
            if (self.mouse_buttons == 0 and c.GetCapture() == hwnd) _ = c.ReleaseCapture();
        },
    }

    if (!self.initialized) return false;
    return self.core_surface.mouseButtonCallback(state, button, mouseMods(wparam)) catch |err| {
        log.warn("error in mouse button callback err={}", .{err});
        return false;
    };
}

const ContextMenuCmd = enum(c.UINT_PTR) {
    copy = 1,
    paste = 2,
    copy_url = 3,
    split_right = 4,
    split_down = 5,
    toggle_split_zoom = 6,
    find = 7,
    clear_screen = 8,
    reset_terminal = 9,
    toggle_inspector = 10,
    command_palette = 11,
};

fn appendContextMenuItem(
    alloc: std.mem.Allocator,
    menu: c.HMENU,
    enabled: bool,
    cmd: ContextMenuCmd,
    label_utf8: [*:0]const u8,
    fallback: [:0]const u16,
) void {
    const flags: c.UINT = if (enabled) c.MF_STRING else c.MF_STRING | c.MF_GRAYED;
    dialogs.appendMenuUtf8(alloc, menu, flags, @backingInt(cmd), label_utf8, fallback);
}

fn showContextMenu(self: *Surface, hwnd: c.HWND, pt_client: c.POINT) void {
    if (!self.initialized or self.detached) return;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const alloc = self.app.core_app.alloc;

    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);

    const has_sel = self.core_surface.hasSelection();
    const has_clip = clipboard.hasText();
    const is_split = if (self.window.tabIndex(self)) |idx|
        self.window.tabs.items[idx].tree.isSplit()
    else
        false;

    appendContextMenuItem(alloc, menu, has_sel, .copy, i18n._("Copy"), L("Copy"));
    appendContextMenuItem(alloc, menu, has_clip, .paste, i18n._("Paste"), L("Paste"));
    if (self.hover_url != null) {
        appendContextMenuItem(alloc, menu, true, .copy_url, i18n._("Copy URL"), L("Copy URL"));
    }
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    appendContextMenuItem(alloc, menu, true, .split_right, i18n._("Split Right"), L("Split Right"));
    appendContextMenuItem(alloc, menu, true, .split_down, i18n._("Split Down"), L("Split Down"));
    appendContextMenuItem(alloc, menu, is_split, .toggle_split_zoom, i18n._("Toggle Split Zoom"), L("Toggle Split Zoom"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    appendContextMenuItem(alloc, menu, true, .find, i18n._("Find\u{2026}"), L("Find\u{2026}"));
    appendContextMenuItem(alloc, menu, true, .clear_screen, i18n._("Clear Screen"), L("Clear Screen"));
    appendContextMenuItem(alloc, menu, true, .reset_terminal, i18n._("Reset Terminal"), L("Reset Terminal"));
    appendContextMenuItem(alloc, menu, true, .toggle_inspector, i18n._("Toggle Terminal Inspector"), L("Toggle Terminal Inspector"));
    appendContextMenuItem(alloc, menu, true, .command_palette, i18n._("Command Palette"), L("Command Palette"));

    if (c.GetCapture() == hwnd) _ = c.ReleaseCapture();
    self.mouse_buttons = 0;
    @memset(&self.core_surface.mouse.click_state, .release);

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
    if (cmd_id == 0 or !self.initialized or self.detached) return;

    const cmd = std.enums.fromInt(ContextMenuCmd, cmd_id) orelse return;
    const action: input.Binding.Action = switch (cmd) {
        .copy => .{ .copy_to_clipboard = .mixed },
        .paste => .paste_from_clipboard,
        .copy_url => .copy_url_to_clipboard,
        .split_right => .{ .new_split = .right },
        .split_down => .{ .new_split = .down },
        .toggle_split_zoom => .toggle_split_zoom,
        .find => .start_search,
        .clear_screen => .clear_screen,
        .reset_terminal => .reset,
        .toggle_inspector => .{ .inspector = .toggle },
        .command_palette => .toggle_command_palette,
    };
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.warn("error performing context menu action err={}", .{err});
    };
}

fn captureLost(self: *Surface) void {
    const buttons = self.mouse_buttons;
    self.mouse_buttons = 0;
    self.mouse_tracking = false;
    self.trackMouseLeave();
    if (buttons == 0 or !self.initialized) return;

    var wparam: c.WPARAM = 0;
    if (c.GetKeyState(c.VK_SHIFT) < 0) wparam |= c.MK_SHIFT;
    if (c.GetKeyState(c.VK_CONTROL) < 0) wparam |= c.MK_CONTROL;
    const mods = mouseMods(wparam);
    for (std.enums.values(input.MouseButton)) |button| {
        const bit = @as(u16, 1) << @intCast(@backingInt(button));
        if (buttons & bit == 0) continue;
        _ = self.core_surface.mouseButtonCallback(.release, button, mods) catch |err| {
            log.warn("error in mouse button callback err={}", .{err});
        };
    }
}

fn wheelSetting(action: c.UINT, default: c.UINT) c.UINT {
    var value: c.UINT = default;
    if (!c.SystemParametersInfoW(action, 0, &value, 0).toBool()) return default;
    return value;
}

fn mouseWheel(self: *Surface, wparam: c.WPARAM, horizontal: bool) void {
    if (!self.initialized) return;
    const delta: i16 = @bitCast(c.hiword(@bitCast(wparam)));
    const notches = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;
    const precision = @rem(delta, 120) != 0;
    const off: f64 = if (!precision) notches else off: {
        const size = self.core_surface.size;
        if (horizontal) {
            const chars = wheelSetting(c.SPI_GETWHEELSCROLLCHARS, 3);
            break :off notches * @as(f64, @floatFromInt(chars)) *
                @as(f64, @floatFromInt(size.cell.width));
        }
        const lines = switch (wheelSetting(c.SPI_GETWHEELSCROLLLINES, 3)) {
            c.WHEEL_PAGESCROLL => size.grid().rows,
            else => |v| v,
        };
        break :off notches * @as(f64, @floatFromInt(lines)) *
            @as(f64, @floatFromInt(size.cell.height));
    };
    self.core_surface.scrollCallback(
        if (horizontal) off else 0,
        if (horizontal) 0 else off,
        .{ .precision = precision },
    ) catch |err| {
        log.warn("error in scroll callback err={}", .{err});
    };
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard, .selection => true,
        .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (!self.supportsClipboard(clipboard_type)) return .unsupported;

    switch (state) {
        .osc_52_write => unreachable,
        .kitty_write => |kitty| {
            const text = textContent(kitty.contents);
            if (kitty.contents.len > 0 and text == null) return .unsupported;
            self.completeClipboard(state, .{}, text orelse "");
            return .started;
        },
        .list => {
            const has_text = switch (clipboard_type) {
                .standard => clipboard.hasText(),
                .selection => if (self.app.selection_clipboard) |s| s.len > 0 else false,
                .primary => false,
            };
            const available: []const []const u8 = if (has_text) &.{"text/plain"} else &.{};
            self.completeClipboard(state, .{ .available = available }, "");
            return .started;
        },
        .paste, .osc_52_read, .kitty_read => {},
    }

    const alloc = self.app.core_app.alloc;
    if (clipboard_type == .selection) {
        const sel = self.app.selection_clipboard orelse return .unavailable;
        if (sel.len == 0) return .unavailable;
        const copy = try alloc.dupe(u8, sel);
        defer alloc.free(copy);
        const contents = [_]terminal.clipboard.Content{.{ .mime = "text/plain", .data = copy }};
        self.completeClipboard(state, .{
            .contents = &contents,
            .available = &.{"text/plain"},
        }, copy);
        return .started;
    }

    const text = clipboard.readText(alloc, self.hwnd) catch |err| switch (err) {
        error.ClipboardBusy => {
            log.warn("clipboard is held by another application", .{});
            return .unavailable;
        },
        else => |e| return e,
    } orelse return .unavailable;
    defer alloc.free(text);

    const contents = [_]terminal.clipboard.Content{.{ .mime = "text/plain", .data = text }};
    self.completeClipboard(state, .{
        .contents = &contents,
        .available = &.{"text/plain"},
    }, text);
    return .started;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (!self.supportsClipboard(clipboard_type)) return;
    const text = textContent(contents);
    const html = htmlContent(contents);
    const preview = text orelse html orelse return;
    if (confirm and !self.confirmClipboard(.write, preview)) return;
    const alloc = self.app.core_app.alloc;
    switch (clipboard_type) {
        .standard => try clipboard.writeTextAndHtml(alloc, self.hwnd, text, html),
        .selection => if (text) |plain| {
            const copy = try alloc.dupeSentinel(u8, plain, 0);
            if (self.app.selection_clipboard) |old| alloc.free(old);
            self.app.selection_clipboard = copy;
        },
        .primary => {},
    }
}

fn textContent(contents: []const apprt.ClipboardContent) ?[:0]const u8 {
    for (contents) |content| {
        if (terminal.clipboard.isTextMime(content.mime)) return content.data;
    }
    return null;
}

fn htmlContent(contents: []const apprt.ClipboardContent) ?[:0]const u8 {
    for (contents) |content| {
        if (std.ascii.startsWithIgnoreCase(content.mime, "text/html")) return content.data;
    }
    return null;
}

pub fn pasteDroppedText(self: *Surface, text: []const u8) void {
    if (!self.initialized or text.len == 0) return;
    const contents = [_]terminal.clipboard.Content{.{ .mime = "text/plain", .data = text }};
    self.completeClipboard(.{ .paste = .standard }, .{
        .contents = &contents,
        .available = &.{"text/plain"},
    }, text);
}

pub fn shellIsCmd(self: *const Surface) bool {
    return self.is_cmd_shell;
}

fn isCmdCommand(cmd_opt: ?configpkg.Command) bool {
    const cmd = cmd_opt orelse return false;
    const exe: []const u8 = switch (cmd) {
        .direct => |args| if (args.len > 0) std.mem.trim(u8, args[0], " \t\"") else return false,
        .shell => |s| blk: {
            const trimmed = std.mem.trimStart(u8, s, " \t");
            if (trimmed.len == 0) return false;
            if (trimmed[0] == '"') {
                const rest = trimmed[1..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse rest.len;
                break :blk rest[0..end];
            }
            const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
            break :blk trimmed[0..end];
        },
    };
    const base_start = if (std.mem.lastIndexOfAny(u8, exe, "\\/")) |idx| idx + 1 else 0;
    const base = exe[base_start..];
    return std.ascii.eqlIgnoreCase(base, "cmd") or std.ascii.eqlIgnoreCase(base, "cmd.exe");
}

fn completeClipboard(
    self: *Surface,
    req: apprt.ClipboardRequest,
    complete: CoreSurface.CompleteClipboard,
    preview: []const u8,
) void {
    self.core_surface.completeClipboardRequest(req, complete) catch |err| switch (err) {
        error.UnsafePaste, error.UnsafePastePassword, error.UnauthorizedPaste => {
            const prompt: ClipboardPrompt = switch (req) {
                .paste, .list => .paste,
                .osc_52_read, .kitty_read => .read,
                .osc_52_write, .kitty_write => .write,
            };
            if (err == error.UnsafePastePassword) self.secure_input = true;
            if (!self.confirmClipboard(prompt, preview)) {
                self.core_surface.denyClipboardRequest(req);
                return;
            }
            var confirmed = complete;
            confirmed.confirmed = true;
            self.core_surface.completeClipboardRequest(req, confirmed) catch |err2| {
                log.warn("error completing clipboard request err={}", .{err2});
            };
        },
        else => log.warn("error completing clipboard request err={}", .{err}),
    };
}

const ClipboardPrompt = enum { paste, read, write };

fn confirmClipboard(self: *Surface, prompt: ClipboardPrompt, text: []const u8) bool {
    const alloc = self.app.core_app.alloc;
    const title: []const u8, const body: []const u8 = switch (prompt) {
        .paste => .{
            "Warning: Potentially Unsafe Paste",
            "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.",
        },
        .read => .{
            "Authorize Clipboard Access",
            "An application is attempting to read from the clipboard. The current clipboard contents are shown below.",
        },
        .write => .{
            "Authorize Clipboard Access",
            "An application is attempting to write to the clipboard. The current clipboard contents are shown below.",
        },
    };

    const hide_preview = prompt == .paste and self.secure_input;
    const message: ?[]u8 = if (hide_preview) null else blk: {
        var end = @min(text.len, 1024);
        while (end < text.len and end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
        const ellipsis = if (end < text.len) "\n…" else "";
        break :blk alloc.print("{s}\n\n{s}{s}", .{ body, text[0..end], ellipsis }) catch return false;
    };
    defer if (message) |m| alloc.free(m);

    return dialogs.confirmUtf8(alloc, if (self.detached) null else self.window.hwnd, .{
        .main = title,
        .content = message orelse body,
        .yes = "Allow",
        .no = "Deny",
        .default_yes = false,
    });
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn renderDeviceOptions(self: *const Surface) !@import("../../renderer.zig").Device.Options {
    _ = self;
    return .{};
}

pub fn skipTranslate(msg: *const c.MSG) bool {
    switch (msg.message) {
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {},
        else => return false,
    }
    const vk: c.UINT = @truncate(msg.wParam & 0xFFFF);
    if (vk == c.VK_PACKET or vk == c.VK_PROCESSKEY) return false;
    const hwnd = msg.hwnd orelse return false;
    const proc: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_WNDPROC));
    return proc == @intFromPtr(&wndProc);
}

fn keyMessage(
    self: *Surface,
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) c.LRESULT {
    const sys_down = msg == c.WM_SYSKEYDOWN;
    if (sys_down) self.sys_char_passthrough = false;
    if (!self.initialized) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    const vk: c.UINT = @truncate(wparam & 0xFFFF);
    const ime_composing = self.ime_state.onKey(hwnd, msg, vk);
    switch (vk) {
        c.VK_PACKET => {
            self.key_down_pending = false;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.VK_PROCESSKEY => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
        c.VK_SHIFT, c.VK_CONTROL, c.VK_MENU, c.VK_LWIN, c.VK_RWIN, c.VK_CAPITAL => {},
        else => self.key_down_pending = msg == c.WM_KEYDOWN or sys_down,
    }
    if (key.isSyntheticAltGrCtrl(vk, lparam)) return 0;

    var event = key.translate(
        msg,
        wparam,
        lparam,
        c.GetKeyboardLayout(0),
        &self.key_utf8,
    ) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    var preedit: ?[]const u8 = null;
    if (ime_composing) {
        event.composing = true;
        event.utf8 = "";
    } else if (event.composing) {
        const len = @min(event.utf8.len, self.preedit_utf8.len);
        @memcpy(self.preedit_utf8[0..len], event.utf8[0..len]);
        preedit = self.preedit_utf8[0..len];
        event.utf8 = "";
    } else if (self.dead_key_pending and event.utf8.len > 0) {
        self.dead_key_pending = false;
        self.core_surface.preeditCallback(null) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    const effect = self.core_surface.keyCallback(event) catch |err| err: {
        log.warn("error in key callback err={}", .{err});
        break :err .ignored;
    };
    if (effect == .closed) return 0;

    if (preedit) |text| {
        self.dead_key_pending = true;
        self.core_surface.preeditCallback(text) catch |err| {
            log.warn("error in preedit callback err={}", .{err});
        };
    }

    if (vk == c.VK_LWIN or vk == c.VK_RWIN) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (effect) {
        .closed, .consumed => return 0,
        .ignored => {
            if (self.app.core_app.keyEvent(self.app, event)) return 0;
            if (!sys_down) return 0;
            self.sys_char_passthrough = true;
            const translate_msg: c.MSG = .{
                .hwnd = hwnd,
                .message = msg,
                .wParam = wparam,
                .lParam = lparam,
                .time = @bitCast(c.GetMessageTime()),
            };
            _ = c.TranslateMessage(&translate_msg);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

fn charMessage(self: *Surface, unit: u16) void {
    if (!self.initialized) return;
    const cp = self.char_decoder.push(unit) orelse return;
    var buf: [4]u8 = undefined;
    const event = key.charEvent(cp, &buf) orelse return;
    _ = self.core_surface.keyCallback(event) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

pub fn imePreedit(self: *Surface, text: ?[]const u8) void {
    if (!self.initialized) return;
    self.dead_key_pending = false;
    self.core_surface.preeditCallback(text) catch |err| {
        log.warn("error in preedit callback err={}", .{err});
    };
}

pub fn imeCommit(self: *Surface, text: []const u8) void {
    if (!self.initialized) return;
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .utf8 = text,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

pub fn imeCaret(self: *Surface) ?ime.Caret {
    if (!self.initialized) return null;
    const pos = self.core_surface.imePoint();
    const sx: f64 = self.content_scale.x;
    const sy: f64 = self.content_scale.y;
    const cell_w: f64 = @floatFromInt(self.core_surface.size.cell.width);
    const height = pos.height * sy;
    return .{
        .x = @intFromFloat(@max(0, pos.x * sx - cell_w / 2)),
        .y = @intFromFloat(@max(0, pos.y * sy - height)),
        .width = @intFromFloat(@max(1, pos.width * sx)),
        .height = @intFromFloat(@max(1, height)),
    };
}

pub fn wndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const self = c.initUserData(Surface, hwnd, lparam);
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = c.userData(Surface, hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    if (self.ime_state.handle(self, self.app.core_app.alloc, hwnd, msg, wparam, lparam)) |result| return result;

    switch (msg) {
        c.WM_SIZE => {
            self.size = .{ .width = c.loword(lparam), .height = c.hiword(lparam) };
            self.overlay.layout();
            self.search_overlay.layout();
            if (self.initialized and self.size.width > 0 and self.size.height > 0) {
                self.core_surface.sizeCallback(self.size) catch |err| {
                    log.warn("error in size callback err={}", .{err});
                };
                const grid = self.core_surface.size.grid();
                self.overlay.notifyGridResize(grid.columns, grid.rows);
            }
            return 0;
        },

        c.WM_DPICHANGED_AFTERPARENT => {
            self.dpiChanged(c.GetDpiForWindow(hwnd));
            self.overlay.updateFont();
            self.search_overlay.updateFont();
            return 0;
        },

        c.WM_PAINT => {
            _ = c.ValidateRect(hwnd, null);
            return 0;
        },

        c.WM_ERASEBKGND => return 1,

        c.WM_GETOBJECT => {
            if (lparam == c.OBJID_CLIENT) return 0;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_SETFOCUS => {
            self.focusChanged(true);
            if (!self.detached) self.window.surfaceFocused(self);
            return 0;
        },

        c.WM_KILLFOCUS => {
            self.focusChanged(false);
            return 0;
        },

        WM_GHOSTTY_FOCUS => {
            self.applyFocus();
            return 0;
        },
        dialogs.WM_GHOSTTY_PROMPT_TITLE => {
            dialogs.promptTitle(self, std.enums.fromInt(apprt.action.PromptTitle, wparam) orelse return 0);
            return 0;
        },

        c.WM_SETCURSOR => if (c.loword(lparam) == c.HTCLIENT) {
            _ = c.SetCursor(self.currentCursor());
            return 1;
        },

        c.WM_MOUSEMOVE => {
            self.mouseMove(wparam, lparam);
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.mouseLeave();
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            _ = self.mouseButton(.press, .left, wparam, lparam);
            return 0;
        },

        c.WM_LBUTTONUP => {
            _ = self.mouseButton(.release, .left, wparam, lparam);
            return 0;
        },

        c.WM_RBUTTONDOWN => {
            _ = self.mouseButton(.press, .right, wparam, lparam);
            return 0;
        },

        c.WM_RBUTTONUP => {
            const consumed = self.mouseButton(.release, .right, wparam, lparam);
            if (!consumed and self.initialized and self.core_surface.config.right_click_action == .@"context-menu") {
                self.showContextMenu(hwnd, c.pointFromLparam(lparam));
            }
            return 0;
        },

        c.WM_CONTEXTMENU => {
            if (self.initialized and self.core_surface.config.right_click_action == .@"context-menu") {
                var pt = c.pointFromLparam(lparam);
                if (pt.x == -1 and pt.y == -1) {
                    pt = .{
                        .x = @intCast(self.size.width / 2),
                        .y = @intCast(self.size.height / 2),
                    };
                } else {
                    _ = c.ScreenToClient(hwnd, &pt);
                }
                self.showContextMenu(hwnd, pt);
            }
            return 0;
        },

        c.WM_MBUTTONDOWN => {
            _ = self.mouseButton(.press, .middle, wparam, lparam);
            return 0;
        },

        c.WM_MBUTTONUP => {
            _ = self.mouseButton(.release, .middle, wparam, lparam);
            return 0;
        },

        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            const button: input.MouseButton = switch (c.hiword(@bitCast(wparam))) {
                c.XBUTTON1 => .eight,
                c.XBUTTON2 => .nine,
                else => .unknown,
            };
            const state: input.MouseButtonState = if (msg == c.WM_XBUTTONDOWN) .press else .release;
            _ = self.mouseButton(state, button, wparam, lparam);
            return 1;
        },

        c.WM_CAPTURECHANGED => {
            if (@as(usize, @bitCast(lparam)) != @intFromPtr(hwnd)) self.captureLost();
            return 0;
        },

        c.WM_MOUSEWHEEL => {
            self.mouseWheel(wparam, false);
            return 0;
        },

        c.WM_MOUSEHWHEEL => {
            self.mouseWheel(wparam, true);
            return 0;
        },

        c.WM_KEYDOWN,
        c.WM_KEYUP,
        c.WM_SYSKEYDOWN,
        c.WM_SYSKEYUP,
        => return self.keyMessage(hwnd, msg, wparam, lparam),

        c.WM_CHAR => {
            if (!self.key_down_pending and !self.ime_state.dedup.skip(@truncate(wparam), c.GetMessageTime())) self.charMessage(@truncate(wparam));
            return 0;
        },

        c.WM_INPUTLANGCHANGE => log.debug("keyboard layout changed hkl=0x{x}", .{@as(usize, @bitCast(lparam))}),

        c.WM_DEADCHAR, c.WM_SYSDEADCHAR => return 0,

        c.WM_SYSCHAR => {
            if (self.sys_char_passthrough) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            return 0;
        },

        else => {},
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
