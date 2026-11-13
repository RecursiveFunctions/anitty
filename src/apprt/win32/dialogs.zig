const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const WM_GHOSTTY_PROMPT_TITLE = c.WM_APP + 0x60;

const IDOK: c_int = 1;
const IDCANCEL: c_int = 2;
const MB_DEFBUTTON2: c.UINT = 0x100;
const MB_ICONINFORMATION: c.UINT = 0x40;
const WM_INITDIALOG: c.UINT = 0x0110;
const WM_COMMAND: c.UINT = 0x0111;
const EM_SETSEL: c.UINT = 0x00B1;
const DWLP_USER: c_int = 16;
const GW_OWNER: c.UINT = 4;

const TDF_ALLOW_DIALOG_CANCELLATION: c_int = 0x0008;
const TDF_POSITION_RELATIVE_TO_WINDOW: c_int = 0x1000;
const TDCBF_OK_BUTTON: c_int = 0x0001;
const TD_WARNING_ICON: usize = 0xFFFF;
const TD_INFORMATION_ICON: usize = 0xFFFD;

const TaskDialogButton = extern struct {
    id: c_int align(1),
    text: c.LPCWSTR align(1),
};

const TaskDialogConfig = extern struct {
    cbSize: c.UINT align(1) = @sizeOf(TaskDialogConfig),
    hwndParent: ?c.HWND align(1) = null,
    hInstance: ?c.HINSTANCE align(1) = null,
    dwFlags: c_int align(1) = 0,
    dwCommonButtons: c_int align(1) = 0,
    pszWindowTitle: ?c.LPCWSTR align(1) = null,
    pszMainIcon: usize align(1) = 0,
    pszMainInstruction: ?c.LPCWSTR align(1) = null,
    pszContent: ?c.LPCWSTR align(1) = null,
    cButtons: c.UINT align(1) = 0,
    pButtons: ?[*]const TaskDialogButton align(1) = null,
    nDefaultButton: c_int align(1) = 0,
    cRadioButtons: c.UINT align(1) = 0,
    pRadioButtons: ?*const anyopaque align(1) = null,
    nDefaultRadioButton: c_int align(1) = 0,
    pszVerificationText: ?c.LPCWSTR align(1) = null,
    pszExpandedInformation: ?c.LPCWSTR align(1) = null,
    pszExpandedControlText: ?c.LPCWSTR align(1) = null,
    pszCollapsedControlText: ?c.LPCWSTR align(1) = null,
    pszFooterIcon: usize align(1) = 0,
    pszFooter: ?c.LPCWSTR align(1) = null,
    pfCallback: ?*const anyopaque align(1) = null,
    lpCallbackData: c.LONG_PTR align(1) = 0,
    cxWidth: c.UINT align(1) = 0,
};

comptime {
    std.debug.assert(@sizeOf(TaskDialogButton) == 12);
    std.debug.assert(@sizeOf(TaskDialogConfig) == 160);
}

const TaskDialogIndirectFn = *const fn (
    config: *const TaskDialogConfig,
    button: ?*c_int,
    radio: ?*c_int,
    verification: ?*c.BOOL,
) callconv(.winapi) c.HRESULT;

const DLGPROC = *const fn (c.HWND, c.UINT, c.WPARAM, c.LPARAM) callconv(.winapi) isize;

extern "kernel32" fn LoadLibraryW(name: c.LPCWSTR) callconv(.winapi) ?c.HINSTANCE;
extern "kernel32" fn GetProcAddress(module: c.HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "user32" fn DialogBoxIndirectParamW(instance: ?c.HINSTANCE, template: *const anyopaque, owner: ?c.HWND, proc: DLGPROC, param: c.LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hwnd: c.HWND, result: isize) callconv(.winapi) c.BOOL;
extern "user32" fn GetDlgItem(hwnd: c.HWND, id: c_int) callconv(.winapi) ?c.HWND;
extern "user32" fn SendMessageW(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT;
extern "user32" fn GetWindowTextLengthW(hwnd: c.HWND) callconv(.winapi) c_int;
extern "user32" fn GetWindowTextW(hwnd: c.HWND, buf: [*]u16, max: c_int) callconv(.winapi) c_int;
extern "user32" fn GetWindow(hwnd: c.HWND, cmd: c.UINT) callconv(.winapi) ?c.HWND;
extern "shell32" fn ShellExecuteW(hwnd: ?c.HWND, op: ?c.LPCWSTR, file: c.LPCWSTR, params: ?c.LPCWSTR, dir: ?c.LPCWSTR, show: c_int) callconv(.winapi) ?c.HINSTANCE;
extern "shell32" fn FindExecutableW(file: c.LPCWSTR, dir: ?c.LPCWSTR, result: [*]u16) callconv(.winapi) ?c.HINSTANCE;
extern "ole32" fn CoCreateInstance(rclsid: *const std.os.windows.GUID, outer: ?*anyopaque, clsctx: c.DWORD, riid: *const std.os.windows.GUID, ppv: *?*anyopaque) callconv(.winapi) c.HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;
const CLSCTX_INPROC_HANDLER: c.DWORD = 0x2;
const CLSCTX_LOCAL_SERVER: c.DWORD = 0x4;
const SIGDN_FILESYSPATH: c.DWORD = 0x80058000;

const CLSID_FileSaveDialog: std.os.windows.GUID = .{
    .Data1 = 0xC0B4E2F3,
    .Data2 = 0xBA21,
    .Data3 = 0x4773,
    .Data4 = .{ 0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B },
};

const IID_IFileDialog: std.os.windows.GUID = .{
    .Data1 = 0x42F85136,
    .Data2 = 0xDB7E,
    .Data3 = 0x439C,
    .Data4 = .{ 0x85, 0xF1, 0xE4, 0x07, 0x5D, 0x13, 0x5F, 0xC8 },
};

const IShellItem = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IShellItem) callconv(.winapi) u32,
        BindToHandler: *const anyopaque,
        GetParent: *const anyopaque,
        GetDisplayName: *const fn (*IShellItem, c.DWORD, *?[*:0]u16) callconv(.winapi) c.HRESULT,
    };
};

const IFileDialog = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IFileDialog) callconv(.winapi) u32,
        Show: *const fn (*IFileDialog, ?c.HWND) callconv(.winapi) c.HRESULT,
        SetFileTypes: *const anyopaque,
        SetFileTypeIndex: *const anyopaque,
        GetFileTypeIndex: *const anyopaque,
        Advise: *const anyopaque,
        Unadvise: *const anyopaque,
        SetOptions: *const anyopaque,
        GetOptions: *const anyopaque,
        SetDefaultFolder: *const anyopaque,
        SetFolder: *const anyopaque,
        GetFolder: *const anyopaque,
        GetCurrentSelection: *const anyopaque,
        SetFileName: *const fn (*IFileDialog, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        GetFileName: *const anyopaque,
        SetTitle: *const fn (*IFileDialog, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        SetOkButtonLabel: *const anyopaque,
        SetFileNameLabel: *const anyopaque,
        GetResult: *const fn (*IFileDialog, *?*IShellItem) callconv(.winapi) c.HRESULT,
    };
};

const CLSID_UIHostNoLaunch: std.os.windows.GUID = .{
    .Data1 = 0x4CE576FA,
    .Data2 = 0x83DC,
    .Data3 = 0x4F88,
    .Data4 = .{ 0x95, 0x1C, 0x9D, 0x07, 0x82, 0xB4, 0xE3, 0x76 },
};

const IID_ITipInvocation: std.os.windows.GUID = .{
    .Data1 = 0x37C994E7,
    .Data2 = 0x432B,
    .Data3 = 0x4834,
    .Data4 = .{ 0xA2, 0xF7, 0xDC, 0xE1, 0xF1, 0x3B, 0x83, 0x4B },
};

const ITipInvocation = extern struct {
    lpVtbl: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*ITipInvocation, *const std.os.windows.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*ITipInvocation) callconv(.winapi) u32,
        Release: *const fn (*ITipInvocation) callconv(.winapi) u32,
        Toggle: *const fn (*ITipInvocation, ?c.HWND) callconv(.winapi) c.HRESULT,
    };
};

pub fn showOnScreenKeyboard() bool {
    var raw: ?*anyopaque = null;
    const hr = CoCreateInstance(
        &CLSID_UIHostNoLaunch,
        null,
        CLSCTX_INPROC_HANDLER | CLSCTX_LOCAL_SERVER,
        &IID_ITipInvocation,
        &raw,
    );
    if (hr >= 0) if (raw) |ptr| {
        const tip: *ITipInvocation = @ptrCast(@alignCast(ptr));
        defer _ = tip.lpVtbl.Release(tip);
        if (tip.lpVtbl.Toggle(tip, c.GetDesktopWindow()) >= 0) return true;
    };
    const res = ShellExecuteW(null, L("open"), L("TabTip.exe"), null, null, c.SW_SHOWNORMAL);
    return @intFromPtr(res) > 32;
}

var task_dialog_fn: ?TaskDialogIndirectFn = null;
var task_dialog_loaded = false;

fn taskDialogIndirect() ?TaskDialogIndirectFn {
    if (task_dialog_loaded) return task_dialog_fn;
    task_dialog_loaded = true;
    const module = LoadLibraryW(L("comctl32.dll")) orelse return null;
    const proc = GetProcAddress(module, "TaskDialogIndirect") orelse return null;
    task_dialog_fn = @ptrCast(proc);
    return task_dialog_fn;
}

pub const Icon = enum { warning, information };

pub const Confirm = struct {
    title: [:0]const u16 = L("Ghostty"),
    main: [:0]const u16,
    content: ?[:0]const u16 = null,
    yes: [:0]const u16,
    no: [:0]const u16 = L("Cancel"),
    default_yes: bool = true,
    icon: Icon = .warning,
};

pub fn confirm(owner: ?c.HWND, opts: Confirm) bool {
    const buttons = [_]TaskDialogButton{
        .{ .id = IDOK, .text = opts.yes.ptr },
        .{ .id = IDCANCEL, .text = opts.no.ptr },
    };
    const config: TaskDialogConfig = .{
        .hwndParent = owner,
        .dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
        .pszWindowTitle = opts.title.ptr,
        .pszMainIcon = iconId(opts.icon),
        .pszMainInstruction = opts.main.ptr,
        .pszContent = if (opts.content) |v| v.ptr else null,
        .cButtons = buttons.len,
        .pButtons = &buttons,
        .nDefaultButton = if (opts.default_yes) IDOK else IDCANCEL,
    };
    if (runTaskDialog(&config)) |button| return button == IDOK;

    const text = opts.content orelse opts.main;
    var flags = c.MB_YESNO | iconFlags(opts.icon);
    if (!opts.default_yes) flags |= MB_DEFBUTTON2;
    return c.MessageBoxW(owner, text, opts.title, flags) == c.IDYES;
}

pub fn info(owner: ?c.HWND, title: [:0]const u16, main: [:0]const u16, content: ?[:0]const u16) void {
    const config: TaskDialogConfig = .{
        .hwndParent = owner,
        .dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW,
        .dwCommonButtons = TDCBF_OK_BUTTON,
        .pszWindowTitle = title.ptr,
        .pszMainIcon = TD_INFORMATION_ICON,
        .pszMainInstruction = main.ptr,
        .pszContent = if (content) |v| v.ptr else null,
    };
    if (runTaskDialog(&config) != null) return;
    _ = c.MessageBoxW(owner, content orelse main, title, c.MB_OK | MB_ICONINFORMATION);
}

fn runTaskDialog(config: *const TaskDialogConfig) ?c_int {
    const func = taskDialogIndirect() orelse return null;
    var button: c_int = IDCANCEL;
    const hr = func(config, &button, null, null);
    if (hr < 0) {
        log.warn("TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return null;
    }
    return button;
}

fn iconId(icon: Icon) usize {
    return switch (icon) {
        .warning => TD_WARNING_ICON,
        .information => TD_INFORMATION_ICON,
    };
}

fn iconFlags(icon: Icon) c.UINT {
    return switch (icon) {
        .warning => c.MB_ICONWARNING,
        .information => MB_ICONINFORMATION,
    };
}

pub const CloseTarget = enum { app, window, tab, surface };

pub fn confirmClose(owner: ?c.HWND, target: CloseTarget) bool {
    return confirm(owner, .{
        .main = switch (target) {
            .app => L("Quit Ghostty?"),
            .window => L("Close Window?"),
            .tab => L("Close Tab?"),
            .surface => L("Close Terminal?"),
        },
        .content = switch (target) {
            .app => L("All terminal sessions will be terminated."),
            .window => L("All terminal sessions in this window will be terminated."),
            .tab => L("All terminal sessions in this tab will be terminated."),
            .surface => L("The currently running process in this terminal will be terminated."),
        },
        .yes = L("Close"),
    });
}

const edit_id: c_int = 100;

const Prompt = struct {
    initial: [:0]const u16,
    result: ?[:0]u16 = null,
    alloc: Allocator,
};

pub fn promptText(
    alloc: Allocator,
    owner: ?c.HWND,
    title: [:0]const u16,
    label: [:0]const u16,
    initial: []const u8,
) !?[:0]u8 {
    const initial_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, initial);
    defer alloc.free(initial_w);

    var template: Template = .{};
    try template.build(title, label);

    var state: Prompt = .{ .initial = initial_w, .alloc = alloc };
    const rc = DialogBoxIndirectParamW(
        c.GetModuleHandleW(null),
        &template.buf,
        owner,
        promptProc,
        @bitCast(@intFromPtr(&state)),
    );
    const wide = state.result orelse return null;
    defer alloc.free(wide);
    if (rc != IDOK) return null;
    return try std.unicode.utf16LeToUtf8AllocZ(alloc, wide);
}

fn promptProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = c.SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state: *Prompt = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (GetDlgItem(hwnd, edit_id)) |edit| {
                _ = c.SetWindowTextW(edit, state.initial);
                _ = SendMessageW(edit, EM_SETSEL, 0, -1);
            }
            centerOnOwner(hwnd);
            return 1;
        },
        WM_COMMAND => {
            const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, DWLP_USER));
            if (ptr == 0) return 0;
            const state: *Prompt = @ptrFromInt(ptr);
            const id: c_int = @intCast(wparam & 0xFFFF);
            switch (id) {
                IDOK => {
                    if (GetDlgItem(hwnd, edit_id)) |edit| {
                        const len: usize = @intCast(@max(0, GetWindowTextLengthW(edit)));
                        if (state.alloc.allocSentinel(u16, len, 0)) |buf| {
                            const n: usize = @intCast(@max(0, GetWindowTextW(edit, buf.ptr, @intCast(len + 1))));
                            buf[n] = 0;
                            state.result = buf[0..n :0];
                        } else |err| log.warn("error reading title err={}", .{err});
                    }
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                IDCANCEL => {
                    _ = EndDialog(hwnd, IDCANCEL);
                    return 1;
                },
                else => {},
            }
        },
        else => {},
    }
    return 0;
}

fn centerOnOwner(hwnd: c.HWND) void {
    const owner = GetWindow(hwnd, GW_OWNER) orelse return;
    var outer: c.RECT = .{};
    var dlg: c.RECT = .{};
    if (!c.GetWindowRect(owner, &outer).toBool()) return;
    if (!c.GetWindowRect(hwnd, &dlg).toBool()) return;
    const w = dlg.right - dlg.left;
    const h = dlg.bottom - dlg.top;
    const x = outer.left + @divTrunc((outer.right - outer.left) - w, 2);
    const y = outer.top + @divTrunc((outer.bottom - outer.top) - h, 2);
    _ = c.SetWindowPos(hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

const Template = struct {
    buf: [1024]u16 align(4) = undefined,
    len: usize = 0,

    const WS_POPUP: u32 = 0x80000000;
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_CAPTION: u32 = 0x00C00000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_SYSMENU: u32 = 0x00080000;
    const WS_TABSTOP: u32 = 0x00010000;
    const DS_MODALFRAME: u32 = 0x80;
    const DS_SHELLFONT: u32 = 0x40 | 0x08;
    const ES_AUTOHSCROLL: u32 = 0x80;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const class_button: u16 = 0x0080;
    const class_edit: u16 = 0x0081;
    const class_static: u16 = 0x0082;

    fn build(self: *Template, title: [:0]const u16, label: [:0]const u16) !void {
        try self.dword(WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME | DS_SHELLFONT);
        try self.dword(0);
        try self.word(4);
        try self.rect(0, 0, 260, 62);
        try self.word(0);
        try self.word(0);
        try self.string(title);
        try self.word(9);
        try self.string(L("MS Shell Dlg"));

        try self.item(WS_CHILD | WS_VISIBLE, 7, 7, 246, 10, 0xFFFF, class_static, label);
        try self.item(WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL, 7, 20, 246, 14, @intCast(edit_id), class_edit, L(""));
        try self.item(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 149, 41, 50, 14, IDOK, class_button, L("OK"));
        try self.item(WS_CHILD | WS_VISIBLE | WS_TABSTOP, 203, 41, 50, 14, IDCANCEL, class_button, L("Cancel"));
    }

    fn item(
        self: *Template,
        style: u32,
        x: i16,
        y: i16,
        cx: i16,
        cy: i16,
        id: u16,
        class: u16,
        text: [:0]const u16,
    ) !void {
        if (self.len % 2 != 0) try self.word(0);
        try self.dword(style);
        try self.dword(0);
        try self.rect(x, y, cx, cy);
        try self.word(id);
        try self.word(0xFFFF);
        try self.word(class);
        try self.string(text);
        try self.word(0);
    }

    fn rect(self: *Template, x: i16, y: i16, cx: i16, cy: i16) !void {
        inline for (.{ x, y, cx, cy }) |v| try self.word(@bitCast(v));
    }

    fn dword(self: *Template, v: u32) !void {
        try self.word(@truncate(v));
        try self.word(@truncate(v >> 16));
    }

    fn word(self: *Template, v: u16) !void {
        if (self.len >= self.buf.len) return error.TemplateTooLarge;
        self.buf[self.len] = v;
        self.len += 1;
    }

    fn string(self: *Template, s: [:0]const u16) !void {
        for (s) |ch| try self.word(ch);
        try self.word(0);
    }
};

pub fn requestPromptTitle(surface: *Surface, kind: apprt.action.PromptTitle) bool {
    const hwnd = surface.hwnd orelse return false;
    return c.PostMessageW(hwnd, WM_GHOSTTY_PROMPT_TITLE, @intCast(@backingInt(kind)), 0).toBool();
}

pub fn promptTitle(surface: *Surface, kind: apprt.action.PromptTitle) void {
    const app = surface.app;
    const alloc = app.core_app.alloc;
    const window = surface.window;
    const current: []const u8, const title: [:0]const u16 = switch (kind) {
        .surface => .{ surface.getEffectiveTitle() orelse "", L("Change Terminal Title") },
        .tab => .{
            if (window.tabIndex(surface)) |i| window.tabTitle(i) else "",
            L("Change Tab Title"),
        },
        .window => .{
            window.title_override orelse
                if (window.tabIndex(surface)) |i| window.tabTitle(i) else "",
            L("Change Window Title"),
        },
    };

    const value = promptText(
        alloc,
        window.hwnd,
        title,
        L("Leave blank to restore the default title."),
        current,
    ) catch |err| {
        log.warn("error showing title prompt err={}", .{err});
        return;
    } orelse return;
    defer alloc.free(value);

    if (!liveSurface(app, surface, window)) return;
    const result = switch (kind) {
        .surface => surface.setTitleOverride(value),
        .tab => window.setTabTitle(surface, value),
        .window => window.setTitleOverride(value),
    };
    result catch |err| log.warn("error setting title err={}", .{err});
}

fn liveSurface(app: *App, surface: *Surface, window: *Window) bool {
    const found = for (app.core_app.surfaces.items) |s| {
        if (s == surface) break true;
    } else false;
    if (!found or surface.window != window) return false;
    return std.mem.indexOfScalar(*Window, app.windows.items, window) != null;
}

pub fn openConfig() !void {
    const alloc = global.alloc();
    const path = try configpkg.edit.openPath(alloc);
    errdefer alloc.free(path);
    const thread = try std.Thread.spawn(.{}, openConfigThread, .{path});
    thread.detach();
}

fn openConfigThread(path: [:0]const u8) void {
    const alloc = global.alloc();
    defer alloc.free(path);

    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(wide);

    const hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
    defer if (hr >= 0) c.CoUninitialize();

    var exe: [261:0]u16 = @splat(0);
    if (@intFromPtr(FindExecutableW(wide, null, &exe)) > 32) {
        const result = ShellExecuteW(null, L("open"), wide, null, null, c.SW_SHOWNORMAL);
        if (@intFromPtr(result) > 32) {
            log.debug("opened config path={s}", .{path});
            return;
        }
        log.warn("ShellExecuteW failed code={} path={s}", .{ @intFromPtr(result), path });
    }

    runEditor(alloc, path) catch |err| {
        log.warn("error opening config in editor err={} path={s}", .{ err, path });
    };
}

fn runEditor(alloc: Allocator, path: []const u8) !void {
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const editor = editor: {
        for ([_][]const u8{ "VISUAL", "EDITOR" }) |name| {
            const value = environ_map.get(name) orelse continue;
            if (std.mem.trim(u8, value, " \t").len > 0) break :editor value;
        }
        break :editor "notepad.exe";
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, editor, " \t");
    while (it.next()) |arg| try argv.append(alloc, arg);
    try argv.append(alloc, path);

    var child = try std.process.spawn(global.io(), .{ .argv = argv.items });
    log.debug("opened config with editor={s} path={s}", .{ editor, path });
    _ = try child.wait(global.io());
}

pub fn exportTerminalIO(surface: *Surface, contents: []const u8) !bool {
    const alloc = surface.app.core_app.alloc;
    var raw_dlg: ?*anyopaque = null;
    const hr = CoCreateInstance(
        &CLSID_FileSaveDialog,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IFileDialog,
        &raw_dlg,
    );
    if (hr < 0 or raw_dlg == null) return false;
    const dlg: *IFileDialog = @ptrCast(@alignCast(raw_dlg.?));
    defer _ = dlg.lpVtbl.Release(dlg);

    _ = dlg.lpVtbl.SetTitle(dlg, L("Export Terminal IO Events"));
    _ = dlg.lpVtbl.SetFileName(dlg, L("ghostty-terminal-io.txt"));
    if (dlg.lpVtbl.Show(dlg, surface.window.hwnd) < 0) return true;

    var item: ?*IShellItem = null;
    if (dlg.lpVtbl.GetResult(dlg, &item) < 0 or item == null) return false;
    defer _ = item.?.lpVtbl.Release(item.?);

    var wide_path: ?[*:0]u16 = null;
    if (item.?.lpVtbl.GetDisplayName(item.?, SIGDN_FILESYSPATH, &wide_path) < 0 or wide_path == null) return false;
    defer CoTaskMemFree(wide_path);

    const path_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(wide_path.?));
    defer alloc.free(path_utf8);

    const file = try std.Io.Dir.createFileAbsolute(global.io(), path_utf8, .{});
    defer file.close(global.io());
    try file.writeStreamingAll(global.io(), contents);
    return true;
}
