const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const i18n = internal_os.i18n;
const App = @import("App.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_jumplist);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const aumid = L("com.mitchellh.ghostty");

pub const Profile = struct {
    name: [:0]const u8,
    command: [:0]const u8,
    icon_path: ?[:0]const u8 = null,

    pub fn deinit(self: *const Profile, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.command);
        if (self.icon_path) |p| alloc.free(p);
    }
};

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: c.DWORD,
};

const PROPVARIANT = extern struct {
    vt: u16 = 0,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    val1: usize = 0,
    val2: usize = 0,
};

const VT_LPWSTR: u16 = 31;

const PKEY_Title: PROPERTYKEY = .{
    .fmtid = .{
        .data1 = 0xF29F85E0,
        .data2 = 0x4FF9,
        .data3 = 0x1068,
        .data4 = .{ 0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9 },
    },
    .pid = 2,
};

const CLSID_DestinationList: GUID = .{
    .data1 = 0x77F10CF0,
    .data2 = 0x3DB5,
    .data3 = 0x4966,
    .data4 = .{ 0xB5, 0x20, 0xB7, 0xC5, 0x4F, 0xD3, 0x5E, 0xD6 },
};

const IID_ICustomDestinationList: GUID = .{
    .data1 = 0x6332DEBF,
    .data2 = 0x87B5,
    .data3 = 0x4670,
    .data4 = .{ 0x90, 0xC0, 0x5E, 0x57, 0xB4, 0x08, 0xA4, 0x9E },
};

const CLSID_EnumerableObjectCollection: GUID = .{
    .data1 = 0x2D3468C1,
    .data2 = 0x36A7,
    .data3 = 0x43B6,
    .data4 = .{ 0xAC, 0x24, 0xD3, 0xF0, 0x2F, 0xD9, 0x60, 0x7A },
};

const IID_IObjectCollection: GUID = .{
    .data1 = 0x5632B1A4,
    .data2 = 0xE38A,
    .data3 = 0x400A,
    .data4 = .{ 0x92, 0x8A, 0xD4, 0xCD, 0x63, 0x23, 0x02, 0x95 },
};

const IID_IObjectArray: GUID = .{
    .data1 = 0x92CA9DCD,
    .data2 = 0x5622,
    .data3 = 0x4BBA,
    .data4 = .{ 0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9 },
};

const CLSID_ShellLink: GUID = .{
    .data1 = 0x00021401,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IID_IShellLinkW: GUID = .{
    .data1 = 0x000214F9,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IID_IPropertyStore: GUID = .{
    .data1 = 0x886D8EEB,
    .data2 = 0x8CF2,
    .data3 = 0x4446,
    .data4 = .{ 0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99 },
};

const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;
const KEY_READ: c.DWORD = 0x20019;
const RRF_RT_REG_SZ: c.DWORD = 0x00000002;

const IUnknown = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

const IObjectCollection = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IObjectCollection, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IObjectCollection) callconv(.winapi) u32,
        Release: *const fn (*IObjectCollection) callconv(.winapi) u32,
        GetCount: *const fn (*IObjectCollection, *c.UINT) callconv(.winapi) c.HRESULT,
        GetAt: *const anyopaque,
        AddObject: *const fn (*IObjectCollection, *anyopaque) callconv(.winapi) c.HRESULT,
        AddFromArray: *const anyopaque,
        RemoveObjectAt: *const anyopaque,
        Clear: *const fn (*IObjectCollection) callconv(.winapi) c.HRESULT,
    };
};

const ICustomDestinationList = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*ICustomDestinationList, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*ICustomDestinationList) callconv(.winapi) u32,
        Release: *const fn (*ICustomDestinationList) callconv(.winapi) u32,
        SetAppID: *const fn (*ICustomDestinationList, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        BeginList: *const fn (*ICustomDestinationList, *c.UINT, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AppendCategory: *const fn (*ICustomDestinationList, c.LPCWSTR, *anyopaque) callconv(.winapi) c.HRESULT,
        AppendKnownCategory: *const anyopaque,
        AddUserTasks: *const fn (*ICustomDestinationList, *anyopaque) callconv(.winapi) c.HRESULT,
        CommitList: *const fn (*ICustomDestinationList) callconv(.winapi) c.HRESULT,
        GetRemovedDestinations: *const anyopaque,
        DeleteList: *const fn (*ICustomDestinationList, ?c.LPCWSTR) callconv(.winapi) c.HRESULT,
        AbortList: *const fn (*ICustomDestinationList) callconv(.winapi) c.HRESULT,
    };
};

const IShellLinkW = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IShellLinkW) callconv(.winapi) u32,
        Release: *const fn (*IShellLinkW) callconv(.winapi) u32,
        GetPath: *const anyopaque,
        GetIDList: *const anyopaque,
        SetIDList: *const anyopaque,
        GetDescription: *const anyopaque,
        SetDescription: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        GetWorkingDirectory: *const anyopaque,
        SetWorkingDirectory: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        GetArguments: *const anyopaque,
        SetArguments: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) c.HRESULT,
        GetHotkey: *const anyopaque,
        SetHotkey: *const anyopaque,
        GetShowCmd: *const anyopaque,
        SetShowCmd: *const anyopaque,
        GetIconLocation: *const anyopaque,
        SetIconLocation: *const fn (*IShellLinkW, c.LPCWSTR, c_int) callconv(.winapi) c.HRESULT,
        SetRelativePath: *const anyopaque,
        Resolve: *const anyopaque,
        SetPath: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) c.HRESULT,
    };
};

const IPropertyStore = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IPropertyStore, *const GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IPropertyStore) callconv(.winapi) u32,
        Release: *const fn (*IPropertyStore) callconv(.winapi) u32,
        GetCount: *const anyopaque,
        GetAt: *const anyopaque,
        GetValue: *const anyopaque,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) c.HRESULT,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) c.HRESULT,
    };
};

extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    context: c.DWORD,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) c.HRESULT;

extern "advapi32" fn RegOpenKeyExW(
    hKey: c.HKEY,
    lpSubKey: ?c.LPCWSTR,
    ulOptions: c.DWORD,
    samDesired: c.DWORD,
    phkResult: *?c.HKEY,
) callconv(.winapi) i32;

extern "advapi32" fn RegEnumKeyExW(
    hKey: c.HKEY,
    dwIndex: c.DWORD,
    lpName: [*]u16,
    lpcchName: *c.DWORD,
    lpReserved: ?*c.DWORD,
    lpClass: ?[*]u16,
    lpcchClass: ?*c.DWORD,
    lpftLastWriteTime: ?*anyopaque,
) callconv(.winapi) i32;

extern "advapi32" fn RegCloseKey(hKey: c.HKEY) callconv(.winapi) i32;

pub fn isValidWslDistroName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or name[0] == '-') return false;
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

fn appendWindowsQuotedArg(buf: *std.ArrayList(u8), alloc: Allocator, arg: []const u8) !void {
    try buf.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
        } else if (ch == '"') {
            try buf.appendNTimes(alloc, '\\', backslashes * 2 + 1);
            try buf.append(alloc, '"');
            backslashes = 0;
        } else {
            if (backslashes > 0) {
                try buf.appendNTimes(alloc, '\\', backslashes);
                backslashes = 0;
            }
            try buf.append(alloc, ch);
        }
    }
    if (backslashes > 0) {
        try buf.appendNTimes(alloc, '\\', backslashes * 2);
    }
    try buf.append(alloc, '"');
}

pub fn formatProfileArgs(alloc: Allocator, profile: Profile) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "+new-window ");

    const cmd_arg = try std.fmt.allocPrint(alloc, "--command={s}", .{profile.command});
    defer alloc.free(cmd_arg);
    try appendWindowsQuotedArg(&buf, alloc, cmd_arg);

    try buf.append(alloc, ' ');

    const title_arg = try std.fmt.allocPrint(alloc, "--title={s}", .{profile.name});
    defer alloc.free(title_arg);
    try appendWindowsQuotedArg(&buf, alloc, title_arg);

    return try buf.toOwnedSliceSentinel(alloc, 0);
}

pub fn formatWslProfile(alloc: Allocator, distro: []const u8) !Profile {
    const name = try std.fmt.allocPrintSentinel(alloc, "WSL: {s}", .{distro}, 0);
    errdefer alloc.free(name);
    const command = try std.fmt.allocPrintSentinel(alloc, "wsl.exe -d {s}", .{distro}, 0);
    errdefer alloc.free(command);
    return .{
        .name = name,
        .command = command,
        .icon_path = try alloc.dupeSentinel(u8, "wsl.exe", 0),
    };
}

pub fn discoverProfiles(alloc: Allocator) !std.ArrayList(Profile) {
    var list: std.ArrayList(Profile) = .empty;
    errdefer {
        for (list.items) |p| p.deinit(alloc);
        list.deinit(alloc);
    }

    var env = global.environMap() catch return list;
    defer env.deinit();

    if (internal_os.path.expand(global.io(), alloc, &env, "pwsh.exe") catch null) |pwsh_path| {
        defer alloc.free(pwsh_path);
        try list.append(alloc, .{
            .name = try alloc.dupeSentinel(u8, "PowerShell 7", 0),
            .command = try alloc.dupeSentinel(u8, "pwsh.exe", 0),
            .icon_path = try alloc.dupeSentinel(u8, pwsh_path, 0),
        });
    }

    if (env.get("SystemRoot")) |root| {
        if (std.fs.path.joinZ(alloc, &.{ root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe" })) |ps_path| {
            if (std.Io.Dir.accessAbsolute(global.io(), ps_path, .{})) {
                try list.append(alloc, .{
                    .name = try alloc.dupeSentinel(u8, "Windows PowerShell", 0),
                    .command = try alloc.dupeSentinel(u8, "powershell.exe", 0),
                    .icon_path = ps_path,
                });
            } else |_| {
                alloc.free(ps_path);
            }
        } else |_| {}
    }

    const comspec = env.get("COMSPEC") orelse "cmd.exe";
    try list.append(alloc, .{
        .name = try alloc.dupeSentinel(u8, "Command Prompt", 0),
        .command = try alloc.dupeSentinel(u8, "cmd.exe", 0),
        .icon_path = try alloc.dupeSentinel(u8, comspec, 0),
    });

    if (env.get("ProgramFiles")) |pf| {
        if (std.fs.path.joinZ(alloc, &.{ pf, "Git", "bin", "bash.exe" })) |git_bash| {
            if (std.Io.Dir.accessAbsolute(global.io(), git_bash, .{})) {
                const normalized = try alloc.dupe(u8, git_bash);
                defer alloc.free(normalized);
                std.mem.replaceScalar(u8, normalized, '\\', '/');
                const cmd = try std.fmt.allocPrintSentinel(alloc, "\"{s}\" -i -l", .{normalized}, 0);
                errdefer alloc.free(cmd);
                try list.append(alloc, .{
                    .name = try alloc.dupeSentinel(u8, "Git Bash", 0),
                    .command = cmd,
                    .icon_path = git_bash,
                });
            } else |_| {
                alloc.free(git_bash);
            }
        } else |_| {}
    }

    discoverWslProfiles(alloc, &list);
    return list;
}

fn discoverWslProfiles(alloc: Allocator, list: *std.ArrayList(Profile)) void {
    if (comptime builtin.os.tag != .windows) return;
    var lxss_key: ?c.HKEY = null;
    if (RegOpenKeyExW(
        c.HKEY_CURRENT_USER,
        L("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"),
        0,
        KEY_READ,
        &lxss_key,
    ) != 0) return;
    const root = lxss_key orelse return;
    defer _ = RegCloseKey(root);

    var index: c.DWORD = 0;
    while (index < 64) : (index += 1) {
        var subkey_name: [256]u16 = undefined;
        var subkey_len: c.DWORD = subkey_name.len;
        if (RegEnumKeyExW(root, index, &subkey_name, &subkey_len, null, null, null, null) != 0) break;
        if (subkey_len == 0 or subkey_len >= subkey_name.len) continue;
        subkey_name[subkey_len] = 0;

        var distro_w: [256]u16 = undefined;
        var distro_bytes: c.DWORD = @sizeOf(@TypeOf(distro_w));
        if (c.RegGetValueW(
            root,
            @ptrCast(&subkey_name),
            L("DistributionName"),
            RRF_RT_REG_SZ,
            null,
            &distro_w,
            &distro_bytes,
        ) != 0) continue;

        const char_len = @min(distro_w.len, distro_bytes / @sizeOf(u16));
        const slice = std.mem.sliceTo(distro_w[0..char_len], 0);
        if (slice.len == 0) continue;

        const distro_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, slice) catch continue;
        defer alloc.free(distro_utf8);
        if (std.mem.startsWith(u8, distro_utf8, "docker-desktop")) continue;
        if (!isValidWslDistroName(distro_utf8)) continue;

        const profile = formatWslProfile(alloc, distro_utf8) catch continue;
        list.append(alloc, profile) catch {
            profile.deinit(alloc);
            return;
        };
    }
}

fn createShellLink(
    alloc: Allocator,
    exe_w: [:0]const u16,
    args_utf8: []const u8,
    title_utf8: []const u8,
    icon_utf8: ?[]const u8,
) ?*IShellLinkW {
    var raw_link: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &raw_link) < 0) return null;
    const link: *IShellLinkW = @ptrCast(@alignCast(raw_link orelse return null));
    var ok = false;
    defer if (!ok) {
        _ = link.vtable.Release(link);
    };

    if (link.vtable.SetPath(link, exe_w.ptr) < 0) return null;

    const args_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, args_utf8) catch return null;
    defer alloc.free(args_w);
    if (link.vtable.SetArguments(link, args_w.ptr) < 0) return null;

    const title_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, title_utf8) catch return null;
    defer alloc.free(title_w);
    _ = link.vtable.SetDescription(link, title_w.ptr);

    if (icon_utf8) |icon| {
        if (std.unicode.utf8ToUtf16LeAllocZ(alloc, icon)) |icon_w| {
            defer alloc.free(icon_w);
            _ = link.vtable.SetIconLocation(link, icon_w.ptr, 0);
        } else |_| {
            _ = link.vtable.SetIconLocation(link, exe_w.ptr, 0);
        }
    } else {
        _ = link.vtable.SetIconLocation(link, exe_w.ptr, 0);
    }

    var raw_store: ?*anyopaque = null;
    if (link.vtable.QueryInterface(link, &IID_IPropertyStore, &raw_store) < 0) return null;
    const store: *IPropertyStore = @ptrCast(@alignCast(raw_store orelse return null));
    defer _ = store.vtable.Release(store);

    var pv: PROPVARIANT = .{
        .vt = VT_LPWSTR,
        .val1 = @intFromPtr(title_w.ptr),
    };
    if (store.vtable.SetValue(store, &PKEY_Title, &pv) < 0) return null;
    if (store.vtable.Commit(store) < 0) return null;

    ok = true;
    return link;
}

pub fn sync(app: *App) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!app.com_initialized) return;
    const alloc = app.core_app.alloc;

    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(global.io(), &exe_buf) catch return;
    const exe_utf8 = exe_buf[0..exe_len];
    const exe_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_utf8) catch return;
    defer alloc.free(exe_w);

    var raw_cdl: ?*anyopaque = null;
    if (CoCreateInstance(
        &CLSID_DestinationList,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_ICustomDestinationList,
        &raw_cdl,
    ) < 0) return;
    const cdl: *ICustomDestinationList = @ptrCast(@alignCast(raw_cdl orelse return));
    defer _ = cdl.vtable.Release(cdl);

    _ = cdl.vtable.SetAppID(cdl, aumid);

    var min_slots: c.UINT = 0;
    var raw_removed: ?*anyopaque = null;
    if (cdl.vtable.BeginList(cdl, &min_slots, &IID_IObjectArray, &raw_removed) < 0) {
        log.debug("ICustomDestinationList.BeginList skipped", .{});
        return;
    }
    if (raw_removed) |ptr| {
        const unk: *IUnknown = @ptrCast(@alignCast(ptr));
        _ = unk.vtable.Release(unk);
    }

    var raw_tasks: ?*anyopaque = null;
    if (CoCreateInstance(
        &CLSID_EnumerableObjectCollection,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IObjectCollection,
        &raw_tasks,
    ) >= 0) {
        if (raw_tasks) |t_ptr| {
            const tasks: *IObjectCollection = @ptrCast(@alignCast(t_ptr));
            defer _ = tasks.vtable.Release(tasks);

            if (createShellLink(alloc, exe_w, "+new-window", std.mem.span(i18n._("New Window")), null)) |link| {
                _ = tasks.vtable.AddObject(tasks, link);
                _ = link.vtable.Release(link);
            }
            if (createShellLink(alloc, exe_w, "+new-tab", std.mem.span(i18n._("New Tab")), null)) |link| {
                _ = tasks.vtable.AddObject(tasks, link);
                _ = link.vtable.Release(link);
            }

            var raw_task_array: ?*anyopaque = null;
            if (tasks.vtable.QueryInterface(tasks, &IID_IObjectArray, &raw_task_array) >= 0) {
                if (raw_task_array) |arr| {
                    _ = cdl.vtable.AddUserTasks(cdl, arr);
                    const unk: *IUnknown = @ptrCast(@alignCast(arr));
                    _ = unk.vtable.Release(unk);
                }
            }
        }
    }

    var profiles: std.ArrayList(Profile) = discoverProfiles(alloc) catch .empty;
    defer {
        for (profiles.items) |p| p.deinit(alloc);
        profiles.deinit(alloc);
    }

    if (profiles.items.len > 0) {
        var raw_prof: ?*anyopaque = null;
        if (CoCreateInstance(
            &CLSID_EnumerableObjectCollection,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_IObjectCollection,
            &raw_prof,
        ) >= 0) {
            if (raw_prof) |p_ptr| {
                const coll: *IObjectCollection = @ptrCast(@alignCast(p_ptr));
                defer _ = coll.vtable.Release(coll);

                for (profiles.items) |prof| {
                    const args = formatProfileArgs(alloc, prof) catch continue;
                    defer alloc.free(args);
                    if (createShellLink(alloc, exe_w, args, prof.name, prof.icon_path)) |link| {
                        _ = coll.vtable.AddObject(coll, link);
                        _ = link.vtable.Release(link);
                    }
                }

                var raw_prof_array: ?*anyopaque = null;
                if (coll.vtable.QueryInterface(coll, &IID_IObjectArray, &raw_prof_array) >= 0) {
                    if (raw_prof_array) |arr| {
                        _ = cdl.vtable.AppendCategory(cdl, L("Profiles"), arr);
                        const unk: *IUnknown = @ptrCast(@alignCast(arr));
                        _ = unk.vtable.Release(unk);
                    }
                }
            }
        }
    }

    _ = cdl.vtable.CommitList(cdl);
}

test "jumplist formatProfileArgs and formatWslProfile" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const wsl = try formatWslProfile(alloc, "Ubuntu-24.04");
    defer wsl.deinit(alloc);
    try testing.expectEqualStrings("WSL: Ubuntu-24.04", wsl.name);
    try testing.expectEqualStrings("wsl.exe -d Ubuntu-24.04", wsl.command);

    const args = try formatProfileArgs(alloc, wsl);
    defer alloc.free(args);
    try testing.expectEqualStrings("+new-window \"--command=wsl.exe -d Ubuntu-24.04\" \"--title=WSL: Ubuntu-24.04\"", args);

    const git_bash: Profile = .{
        .name = "Git Bash",
        .command = "\"C:/Program Files/Git/bin/bash.exe\" -i -l",
    };
    const gb_args = try formatProfileArgs(alloc, git_bash);
    defer alloc.free(gb_args);
    try testing.expectEqualStrings(
        "+new-window \"--command=\\\"C:/Program Files/Git/bin/bash.exe\\\" -i -l\" \"--title=Git Bash\"",
        gb_args,
    );

    try testing.expect(isValidWslDistroName("Ubuntu-24.04"));
    try testing.expect(!isValidWslDistroName("-e"));
    try testing.expect(!isValidWslDistroName("Ubuntu \"--command=calc.exe\""));
}
