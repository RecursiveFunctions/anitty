const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const internal_os = @import("../../os/main.zig");
const i18n = @import("../../os/main.zig").i18n;
const windows = @import("../../os/windows.zig");
const App = @import("App.zig");
const c = @import("c.zig");
const dialogs = @import("dialogs.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const WM_GHOSTTY_UPDATE_RESULT: c.UINT = c.WM_APP + 6;
pub const WM_GHOSTTY_UPDATE_APPLY: c.UINT = c.WM_APP + 7;

const releases_page_url = "https://github.com/RecursiveFunctions/ghostty-windows/releases/latest";
const api_host = L("api.github.com");
const api_path = L("/repos/RecursiveFunctions/ghostty-windows/releases/latest");
const api_headers = L("Accept: application/vnd.github+json\r\n");

pub const setup_asset_name = "Ghostty-Windows-Setup-x64.exe";
pub const zip_asset_name = "Ghostty-Windows-x64.zip";
pub const sha256_asset_name = "SHA256SUMS.txt";

pub const InstallKind = enum {
    installer,
    portable,
    unknown,
};

const HINTERNET = *opaque {};
const INTERNET_PORT = u16;
const INTERNET_DEFAULT_HTTPS_PORT: INTERNET_PORT = 443;
const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: c.DWORD = 4;
const WINHTTP_FLAG_SECURE: c.DWORD = 0x00800000;
const WINHTTP_QUERY_STATUS_CODE: c.DWORD = 19;
const WINHTTP_QUERY_FLAG_NUMBER: c.DWORD = 0x20000000;

const LOAD_LIBRARY_SEARCH_SYSTEM32: c.DWORD = 0x00000800;
const MOVEFILE_REPLACE_EXISTING: c.DWORD = 0x00000001;
const CREATE_NO_WINDOW: c.DWORD = 0x08000000;

extern "kernel32" fn LoadLibraryExW(name: c.LPCWSTR, hFile: ?*anyopaque, dwFlags: c.DWORD) callconv(.winapi) ?c.HINSTANCE;
extern "kernel32" fn GetProcAddress(module: c.HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn CreateDirectoryW(lpPathName: c.LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) c.BOOL;
extern "kernel32" fn DeleteFileW(lpFileName: c.LPCWSTR) callconv(.winapi) c.BOOL;
extern "kernel32" fn MoveFileExW(lpExistingFileName: c.LPCWSTR, lpNewFileName: ?c.LPCWSTR, dwFlags: c.DWORD) callconv(.winapi) c.BOOL;
extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: c.UINT) callconv(.winapi) c.UINT;

fn systemPowerShellPath(alloc: Allocator) ![:0]u16 {
    var sys_buf: [512]u16 = undefined;
    const len = GetSystemDirectoryW(&sys_buf, sys_buf.len);
    if (len == 0 or len >= sys_buf.len) return error.SystemDirectoryUnavailable;
    const suffix = L("\\WindowsPowerShell\\v1.0\\powershell.exe");
    const out = try alloc.allocSentinel(u16, len + suffix.len, 0);
    @memcpy(out[0..len], sys_buf[0..len]);
    @memcpy(out[len .. len + suffix.len], suffix);
    return out;
}

const WinHttpOpenFn = *const fn (
    pszAgentW: ?c.LPCWSTR,
    dwAccessType: c.DWORD,
    pszProxyW: ?c.LPCWSTR,
    pszProxyBypassW: ?c.LPCWSTR,
    dwFlags: c.DWORD,
) callconv(.winapi) ?HINTERNET;

const WinHttpConnectFn = *const fn (
    hSession: HINTERNET,
    pswzServerName: c.LPCWSTR,
    nServerPort: INTERNET_PORT,
    dwReserved: c.DWORD,
) callconv(.winapi) ?HINTERNET;

const WinHttpOpenRequestFn = *const fn (
    hConnect: HINTERNET,
    pwszVerb: ?c.LPCWSTR,
    pwszObjectName: ?c.LPCWSTR,
    pwszVersion: ?c.LPCWSTR,
    pwszReferrer: ?c.LPCWSTR,
    ppwszAcceptTypes: ?*const ?c.LPCWSTR,
    dwFlags: c.DWORD,
) callconv(.winapi) ?HINTERNET;

const WinHttpSetTimeoutsFn = *const fn (
    hInternet: HINTERNET,
    nResolveTimeout: c_int,
    nConnectTimeout: c_int,
    nSendTimeout: c_int,
    nReceiveTimeout: c_int,
) callconv(.winapi) c.BOOL;

const WinHttpSendRequestFn = *const fn (
    hRequest: HINTERNET,
    lpszHeaders: ?c.LPCWSTR,
    dwHeadersLength: c.DWORD,
    lpOptional: ?*const anyopaque,
    dwOptionalLength: c.DWORD,
    dwTotalLength: c.DWORD,
    dwContext: usize,
) callconv(.winapi) c.BOOL;

const WinHttpReceiveResponseFn = *const fn (
    hRequest: HINTERNET,
    lpReserved: ?*anyopaque,
) callconv(.winapi) c.BOOL;

const WinHttpQueryHeadersFn = *const fn (
    hRequest: HINTERNET,
    dwInfoLevel: c.DWORD,
    pwszName: ?c.LPCWSTR,
    lpBuffer: *anyopaque,
    lpdwBufferLength: *c.DWORD,
    lpdwIndex: ?*c.DWORD,
) callconv(.winapi) c.BOOL;

const WinHttpReadDataFn = *const fn (
    hRequest: HINTERNET,
    lpBuffer: *anyopaque,
    dwNumberOfBytesToRead: c.DWORD,
    lpdwNumberOfBytesRead: *c.DWORD,
) callconv(.winapi) c.BOOL;

const WinHttpCloseHandleFn = *const fn (
    hInternet: HINTERNET,
) callconv(.winapi) c.BOOL;

const WinHttpApis = struct {
    WinHttpOpen: WinHttpOpenFn,
    WinHttpConnect: WinHttpConnectFn,
    WinHttpOpenRequest: WinHttpOpenRequestFn,
    WinHttpSetTimeouts: WinHttpSetTimeoutsFn,
    WinHttpSendRequest: WinHttpSendRequestFn,
    WinHttpReceiveResponse: WinHttpReceiveResponseFn,
    WinHttpQueryHeaders: WinHttpQueryHeadersFn,
    WinHttpReadData: WinHttpReadDataFn,
    WinHttpCloseHandle: WinHttpCloseHandleFn,
};

var winhttp_apis: ?WinHttpApis = null;
var winhttp_loaded: std.atomic.Value(bool) = .init(false);

fn loadWinHttp() ?WinHttpApis {
    if (winhttp_loaded.load(.acquire)) return winhttp_apis;
    const mod = LoadLibraryExW(L("winhttp.dll"), null, LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
        winhttp_loaded.store(true, .release);
        return null;
    };
    const apis: WinHttpApis = .{
        .WinHttpOpen = @ptrCast(GetProcAddress(mod, "WinHttpOpen") orelse return null),
        .WinHttpConnect = @ptrCast(GetProcAddress(mod, "WinHttpConnect") orelse return null),
        .WinHttpOpenRequest = @ptrCast(GetProcAddress(mod, "WinHttpOpenRequest") orelse return null),
        .WinHttpSetTimeouts = @ptrCast(GetProcAddress(mod, "WinHttpSetTimeouts") orelse return null),
        .WinHttpSendRequest = @ptrCast(GetProcAddress(mod, "WinHttpSendRequest") orelse return null),
        .WinHttpReceiveResponse = @ptrCast(GetProcAddress(mod, "WinHttpReceiveResponse") orelse return null),
        .WinHttpQueryHeaders = @ptrCast(GetProcAddress(mod, "WinHttpQueryHeaders") orelse return null),
        .WinHttpReadData = @ptrCast(GetProcAddress(mod, "WinHttpReadData") orelse return null),
        .WinHttpCloseHandle = @ptrCast(GetProcAddress(mod, "WinHttpCloseHandle") orelse return null),
    };
    winhttp_apis = apis;
    winhttp_loaded.store(true, .release);
    return apis;
}

pub fn cleanupOldExecutable() void {
    if (comptime builtin.os.tag != .windows) return;
    var exe_buf: [2048]u16 = undefined;
    const len = windows.exp.kernel32.GetModuleFileNameW(null, &exe_buf, exe_buf.len - 8);
    if (len == 0 or len >= exe_buf.len - 8) return;

    const suffix = L(".old");
    @memcpy(exe_buf[len .. len + suffix.len], suffix);
    exe_buf[len + suffix.len] = 0;
    _ = DeleteFileW(@ptrCast(&exe_buf));

    const exe_slice = exe_buf[0..len];
    if (std.mem.lastIndexOfAny(u16, exe_slice, &.{ '\\', '/' })) |sep| {
        const dir = exe_slice[0 .. sep + 1];
        const conpty_old = L("conpty.dll.old");
        if (dir.len + conpty_old.len < exe_buf.len) {
            @memcpy(exe_buf[dir.len .. dir.len + conpty_old.len], conpty_old);
            exe_buf[dir.len + conpty_old.len] = 0;
            _ = DeleteFileW(@ptrCast(&exe_buf));
        }
    }
}

pub fn detectInstallKind() InstallKind {
    if (comptime builtin.os.tag != .windows) return .unknown;
    var exe_buf: [2048]u16 = undefined;
    const len = windows.exp.kernel32.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (len == 0 or len >= exe_buf.len) return .unknown;

    const exe_slice = exe_buf[0..len];
    const bin_sep = std.mem.lastIndexOfAny(u16, exe_slice, &.{ '\\', '/' }) orelse return .unknown;
    const bin_dir = exe_slice[0..bin_sep];
    const root_sep = std.mem.lastIndexOfAny(u16, bin_dir, &.{ '\\', '/' }) orelse return .unknown;
    const root_dir = bin_dir[0..root_sep];

    var path_buf: [2048]u16 = undefined;
    const unins_suffix = L("\\unins000.exe");
    if (root_dir.len + unins_suffix.len < path_buf.len) {
        @memcpy(path_buf[0..root_dir.len], root_dir);
        @memcpy(path_buf[root_dir.len .. root_dir.len + unins_suffix.len], unins_suffix);
        path_buf[root_dir.len + unins_suffix.len] = 0;
        const attrs = windows.exp.kernel32.GetFileAttributesW(@ptrCast(&path_buf));
        if (attrs != windows.INVALID_FILE_ATTRIBUTES and (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) == 0) {
            return .installer;
        }
    }

    const share_suffix = L("\\share\\ghostty");
    if (root_dir.len + share_suffix.len < path_buf.len) {
        @memcpy(path_buf[0..root_dir.len], root_dir);
        @memcpy(path_buf[root_dir.len .. root_dir.len + share_suffix.len], share_suffix);
        path_buf[root_dir.len + share_suffix.len] = 0;
        const attrs = windows.exp.kernel32.GetFileAttributesW(@ptrCast(&path_buf));
        if (attrs != windows.INVALID_FILE_ATTRIBUTES and (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0) {
            return .portable;
        }
    }

    return .unknown;
}

const Result = struct {
    tag_name: ?[:0]u8 = null,
    html_url: ?[:0]u8 = null,
    setup_url: ?[:0]u8 = null,
    zip_url: ?[:0]u8 = null,
    sha256_url: ?[:0]u8 = null,

    fn deinit(self: *Result, alloc: Allocator) void {
        if (self.tag_name) |v| alloc.free(v);
        if (self.html_url) |v| alloc.free(v);
        if (self.setup_url) |v| alloc.free(v);
        if (self.zip_url) |v| alloc.free(v);
        if (self.sha256_url) |v| alloc.free(v);
        alloc.destroy(self);
    }
};

var checking: std.atomic.Value(bool) = .init(false);
var downloading: std.atomic.Value(bool) = .init(false);

pub fn checkForUpdates(app: *App) bool {
    const hwnd = app.msg_hwnd orelse return false;
    if (checking.swap(true, .acq_rel)) return true;

    const thread = std.Thread.spawn(.{}, workerThread, .{ app.core_app.alloc, hwnd }) catch |err| {
        log.warn("failed to spawn update check thread err={}", .{err});
        checking.store(false, .release);
        return false;
    };
    thread.detach();
    return true;
}

fn workerThread(alloc: Allocator, msg_hwnd: c.HWND) void {
    defer checking.store(false, .release);

    const result = alloc.create(Result) catch return;
    result.* = .{};

    if (fetchLatestRelease(alloc)) |info| {
        result.tag_name = info.tag_name;
        result.html_url = info.html_url;
        result.setup_url = info.setup_url;
        result.zip_url = info.zip_url;
        result.sha256_url = info.sha256_url;
    } else |err| {
        log.warn("update check failed err={}", .{err});
    }

    if (!c.PostMessageW(
        msg_hwnd,
        WM_GHOSTTY_UPDATE_RESULT,
        0,
        @bitCast(@intFromPtr(result)),
    ).toBool()) {
        result.deinit(alloc);
    }
}

pub const ReleaseInfo = struct {
    tag_name: [:0]u8,
    html_url: [:0]u8,
    setup_url: ?[:0]u8 = null,
    zip_url: ?[:0]u8 = null,
    sha256_url: ?[:0]u8 = null,

    pub fn deinit(self: *ReleaseInfo, alloc: Allocator) void {
        alloc.free(self.tag_name);
        alloc.free(self.html_url);
        if (self.setup_url) |v| alloc.free(v);
        if (self.zip_url) |v| alloc.free(v);
        if (self.sha256_url) |v| alloc.free(v);
    }
};

pub fn parseReleaseJson(alloc: Allocator, json_bytes: []const u8) !ReleaseInfo {
    const AssetJson = struct {
        name: []const u8 = "",
        browser_download_url: []const u8 = "",
    };

    var parsed = try std.json.parseFromSlice(
        struct {
            tag_name: []const u8,
            html_url: []const u8 = releases_page_url,
            assets: []const AssetJson = &.{},
        },
        alloc,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const tag = try alloc.dupeSentinel(u8, parsed.value.tag_name, 0);
    errdefer alloc.free(tag);

    const safe_url = if (isSafeHttpsUrl(parsed.value.html_url))
        parsed.value.html_url
    else
        releases_page_url;
    const url = try alloc.dupeSentinel(u8, safe_url, 0);
    errdefer alloc.free(url);

    var setup_url: ?[:0]u8 = null;
    errdefer if (setup_url) |v| alloc.free(v);
    var zip_url: ?[:0]u8 = null;
    errdefer if (zip_url) |v| alloc.free(v);
    var sha256_url: ?[:0]u8 = null;
    errdefer if (sha256_url) |v| alloc.free(v);

    for (parsed.value.assets) |asset| {
        if (!isAllowedReleaseAssetUrl(asset.browser_download_url)) continue;
        if (std.ascii.eqlIgnoreCase(asset.name, setup_asset_name)) {
            if (setup_url == null) setup_url = try alloc.dupeSentinel(u8, asset.browser_download_url, 0);
        } else if (std.ascii.eqlIgnoreCase(asset.name, zip_asset_name)) {
            if (zip_url == null) zip_url = try alloc.dupeSentinel(u8, asset.browser_download_url, 0);
        } else if (std.ascii.eqlIgnoreCase(asset.name, sha256_asset_name)) {
            if (sha256_url == null) sha256_url = try alloc.dupeSentinel(u8, asset.browser_download_url, 0);
        }
    }

    return .{
        .tag_name = tag,
        .html_url = url,
        .setup_url = setup_url,
        .zip_url = zip_url,
        .sha256_url = sha256_url,
    };
}

fn fetchLatestRelease(alloc: Allocator) !ReleaseInfo {
    const http = loadWinHttp() orelse return error.WinHttpLoadFailed;

    const session = http.WinHttpOpen(
        L("Ghostty-Windows-Updater/1.0"),
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        null,
        null,
        0,
    ) orelse return error.WinHttpOpenFailed;
    defer _ = http.WinHttpCloseHandle(session);

    _ = http.WinHttpSetTimeouts(session, 5000, 5000, 5000, 10000);

    const connect = http.WinHttpConnect(
        session,
        api_host,
        INTERNET_DEFAULT_HTTPS_PORT,
        0,
    ) orelse return error.WinHttpConnectFailed;
    defer _ = http.WinHttpCloseHandle(connect);

    const request = http.WinHttpOpenRequest(
        connect,
        L("GET"),
        api_path,
        null,
        null,
        null,
        WINHTTP_FLAG_SECURE,
    ) orelse return error.WinHttpOpenRequestFailed;
    defer _ = http.WinHttpCloseHandle(request);

    if (!http.WinHttpSendRequest(
        request,
        api_headers,
        std.math.maxInt(c.DWORD),
        null,
        0,
        0,
        0,
    ).toBool()) return error.WinHttpSendRequestFailed;

    if (!http.WinHttpReceiveResponse(request, null).toBool()) {
        return error.WinHttpReceiveResponseFailed;
    }

    var status_code: c.DWORD = 0;
    var status_size: c.DWORD = @sizeOf(c.DWORD);
    if (!http.WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &status_code,
        &status_size,
        null,
    ).toBool() or status_code != 200) {
        return error.HttpStatusNotOk;
    }

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        var read_bytes: c.DWORD = 0;
        if (!http.WinHttpReadData(request, &buf, buf.len, &read_bytes).toBool()) {
            return error.WinHttpReadDataFailed;
        }
        if (read_bytes == 0) break;
        if (body.items.len + read_bytes > 512 * 1024) return error.ResponseTooLarge;
        try body.appendSlice(alloc, buf[0..read_bytes]);
    }

    return try parseReleaseJson(alloc, body.items);
}

pub fn isSafeHttpsUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    for (url) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return false;
    }
    return true;
}

pub fn isAllowedReleaseAssetUrl(url: []const u8) bool {
    if (!isSafeHttpsUrl(url)) return false;
    return std.mem.startsWith(u8, url, "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/") or
        std.mem.startsWith(u8, url, "https://objects.githubusercontent.com/") or
        std.mem.startsWith(u8, url, "https://release-assets.githubusercontent.com/");
}

pub const ParsedHttpsUrl = struct {
    host: []const u8,
    path: []const u8,
};

pub fn parseHttpsUrl(url: []const u8) !ParsedHttpsUrl {
    if (!isSafeHttpsUrl(url)) return error.InvalidHttpsUrl;
    const after_scheme = url["https://".len..];
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return error.InvalidHttpsUrl;
    const host = after_scheme[0..slash];
    const path = after_scheme[slash..];
    if (host.len == 0 or path.len == 0) return error.InvalidHttpsUrl;
    return .{ .host = host, .path = path };
}

pub fn parseSha256Sums(sums_text: []const u8, asset_name: []const u8) ?[32]u8 {
    var lines = std.mem.splitScalar(u8, sums_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) continue;
        const hex_part = line[0..64];
        var rest = std.mem.trimStart(u8, line[64..], " \t");
        if (rest.len > 0 and rest[0] == '*') rest = rest[1..];
        rest = std.mem.trim(u8, rest, " \t\r");
        if (!std.ascii.eqlIgnoreCase(rest, asset_name)) continue;

        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, hex_part) catch continue;
        return digest;
    }
    return null;
}

pub fn escapePowerShellSingleQuoted(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (input) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "''");
        } else {
            try out.append(alloc, ch);
        }
    }
    return try out.toOwnedSlice(alloc);
}

const DownloadJob = struct {
    alloc: Allocator,
    msg_hwnd: c.HWND,
    install_kind: InstallKind,
    html_url: [:0]u8,
    asset_name: []const u8,
    asset_url: [:0]u8,
    sha256_url: [:0]u8,

    fn deinit(self: *DownloadJob) void {
        const alloc = self.alloc;
        alloc.free(self.html_url);
        alloc.free(self.asset_url);
        alloc.free(self.sha256_url);
        alloc.destroy(self);
    }
};

const ApplyResult = struct {
    success: bool = false,
    install_kind: InstallKind = .unknown,
    html_url: [:0]u8,
    temp_dir_w: ?[:0]u16 = null,
    staged_path_w: ?[:0]u16 = null,
    error_msg: ?[:0]u8 = null,

    fn deinit(self: *ApplyResult, alloc: Allocator) void {
        alloc.free(self.html_url);
        if (self.temp_dir_w) |v| alloc.free(v);
        if (self.staged_path_w) |v| alloc.free(v);
        if (self.error_msg) |v| alloc.free(v);
        alloc.destroy(self);
    }
};

pub fn handleResult(app: *App, lparam: c.LPARAM) void {
    const alloc = app.core_app.alloc;
    if (lparam == 0) return;
    const result: *Result = @ptrFromInt(@as(usize, @bitCast(lparam)));
    defer result.deinit(alloc);

    if (app.quitting) return;
    const owner: ?c.HWND = if (app.activeWindow()) |w| w.hwnd else null;

    const tag = result.tag_name orelse {
        const main_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Unable to Check for Updates"))) catch return;
        defer alloc.free(main_w);
        const content_w = std.unicode.utf8ToUtf16LeAllocZ(
            alloc,
            std.mem.span(i18n._("Could not reach GitHub Releases. Would you like to open the releases page in your browser?")),
        ) catch return;
        defer alloc.free(content_w);
        const yes_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Open Releases Page"))) catch return;
        defer alloc.free(yes_w);
        const no_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Cancel"))) catch return;
        defer alloc.free(no_w);

        if (dialogs.confirm(owner, .{
            .main = main_w,
            .content = content_w,
            .yes = yes_w,
            .no = no_w,
            .icon = .information,
        })) {
            internal_os.open(.html, releases_page_url) catch {};
        }
        return;
    };

    const url = result.html_url orelse releases_page_url;
    if (!isNewerVersion(build_config.version_string, tag)) {
        const msg = std.fmt.allocPrint(
            alloc,
            "You are running Ghostty {s} (latest release: {s}).",
            .{ build_config.version_string, tag },
        ) catch return;
        defer alloc.free(msg);
        const content_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, msg) catch return;
        defer alloc.free(content_w);
        const main_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Ghostty is Up to Date"))) catch return;
        defer alloc.free(main_w);
        dialogs.info(owner, L("Ghostty"), main_w, content_w);
        return;
    }

    const install_kind = detectInstallKind();
    const maybe_asset_url: ?[:0]const u8 = switch (install_kind) {
        .installer => result.setup_url,
        .portable => result.zip_url,
        .unknown => null,
    };
    const asset_name: []const u8 = switch (install_kind) {
        .installer => setup_asset_name,
        .portable => zip_asset_name,
        .unknown => "",
    };

    if (maybe_asset_url != null and result.sha256_url != null) {
        const mode_desc = switch (install_kind) {
            .installer => "installer",
            .portable => "portable package",
            .unknown => unreachable,
        };
        const msg = std.fmt.allocPrint(
            alloc,
            "Ghostty {s} is available (current version: {s}).\n\nWould you like to automatically download, verify (SHA-256), and install the {s} update now?",
            .{ tag, build_config.version_string, mode_desc },
        ) catch return;
        defer alloc.free(msg);
        const content_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, msg) catch return;
        defer alloc.free(content_w);
        const main_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Update Available"))) catch return;
        defer alloc.free(main_w);
        const yes_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Install & Restart"))) catch return;
        defer alloc.free(yes_w);
        const no_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Later"))) catch return;
        defer alloc.free(no_w);

        if (dialogs.confirm(owner, .{
            .main = main_w,
            .content = content_w,
            .yes = yes_w,
            .no = no_w,
            .icon = .information,
        })) {
            if (!startDownloadAndApply(
                app,
                install_kind,
                url,
                asset_name,
                maybe_asset_url.?,
                result.sha256_url.?,
            )) {
                internal_os.open(.html, url) catch {};
            }
        }
        return;
    }

    const msg = std.fmt.allocPrint(
        alloc,
        "Ghostty {s} is available (current version: {s}).\n\nWould you like to open the release page to download it?",
        .{ tag, build_config.version_string },
    ) catch return;
    defer alloc.free(msg);
    const content_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, msg) catch return;
    defer alloc.free(content_w);
    const main_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Update Available"))) catch return;
    defer alloc.free(main_w);
    const yes_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Download Update"))) catch return;
    defer alloc.free(yes_w);
    const no_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Later"))) catch return;
    defer alloc.free(no_w);

    if (dialogs.confirm(owner, .{
        .main = main_w,
        .content = content_w,
        .yes = yes_w,
        .no = no_w,
        .icon = .information,
    })) {
        internal_os.open(.html, url) catch {};
    }
}

fn startDownloadAndApply(
    app: *App,
    install_kind: InstallKind,
    html_url: []const u8,
    asset_name: []const u8,
    asset_url: []const u8,
    sha256_url: []const u8,
) bool {
    const hwnd = app.msg_hwnd orelse return false;
    if (downloading.swap(true, .acq_rel)) return true;

    const alloc = app.core_app.alloc;
    const job = alloc.create(DownloadJob) catch {
        downloading.store(false, .release);
        return false;
    };
    const html_copy = alloc.dupeSentinel(u8, html_url, 0) catch {
        alloc.destroy(job);
        downloading.store(false, .release);
        return false;
    };
    const asset_copy = alloc.dupeSentinel(u8, asset_url, 0) catch {
        alloc.free(html_copy);
        alloc.destroy(job);
        downloading.store(false, .release);
        return false;
    };
    const sha_copy = alloc.dupeSentinel(u8, sha256_url, 0) catch {
        alloc.free(asset_copy);
        alloc.free(html_copy);
        alloc.destroy(job);
        downloading.store(false, .release);
        return false;
    };

    job.* = .{
        .alloc = alloc,
        .msg_hwnd = hwnd,
        .install_kind = install_kind,
        .html_url = html_copy,
        .asset_name = asset_name,
        .asset_url = asset_copy,
        .sha256_url = sha_copy,
    };

    const thread = std.Thread.spawn(.{}, downloadAndApplyThread, .{job}) catch |err| {
        log.warn("failed to spawn update download thread err={}", .{err});
        job.deinit();
        downloading.store(false, .release);
        return false;
    };
    thread.detach();
    return true;
}

fn downloadAndApplyThread(job: *DownloadJob) void {
    defer downloading.store(false, .release);
    defer job.deinit();

    const alloc = job.alloc;
    const apply = alloc.create(ApplyResult) catch return;
    const html_copy = alloc.dupeSentinel(u8, job.html_url, 0) catch {
        alloc.destroy(apply);
        return;
    };
    apply.* = .{
        .install_kind = job.install_kind,
        .html_url = html_copy,
    };

    performDownloadAndVerify(job, apply) catch |err| {
        log.warn("in-app update download/verify failed err={}", .{err});
        apply.success = false;
        if (apply.error_msg == null) {
            apply.error_msg = std.fmt.allocPrintSentinel(
                alloc,
                "{s}",
                .{@errorName(err)},
                0,
            ) catch null;
        }
    };

    if (!c.PostMessageW(
        job.msg_hwnd,
        WM_GHOSTTY_UPDATE_APPLY,
        0,
        @bitCast(@intFromPtr(apply)),
    ).toBool()) {
        apply.deinit(alloc);
    }
}

fn performDownloadAndVerify(job: *DownloadJob, apply: *ApplyResult) !void {
    const alloc = job.alloc;

    const sums_bytes = try downloadUrlBytes(alloc, job.sha256_url, 64 * 1024);
    defer alloc.free(sums_bytes);

    const expected_sha256 = parseSha256Sums(sums_bytes, job.asset_name) orelse {
        return error.MissingAssetChecksum;
    };

    var temp_buf: [windows.MAX_PATH + 1]u16 = undefined;
    const temp_len = windows.exp.kernel32.GetTempPathW(windows.MAX_PATH + 1, @ptrCast(&temp_buf));
    if (temp_len == 0 or temp_len > windows.MAX_PATH) return error.GetTempPathFailed;

    const temp_base_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, temp_buf[0..temp_len]);
    defer alloc.free(temp_base_utf8);

    const tick = c.GetTickCount64();
    const trimmed_base = std.mem.trimEnd(u8, temp_base_utf8, "\\/");
    const temp_dir_utf8 = try std.fmt.allocPrint(alloc, "{s}\\ghostty-update-{d}", .{ trimmed_base, tick });
    defer alloc.free(temp_dir_utf8);

    const temp_dir_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, temp_dir_utf8);
    apply.temp_dir_w = temp_dir_w;
    _ = CreateDirectoryW(temp_dir_w, null);

    const dest_file_utf8 = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ temp_dir_utf8, job.asset_name });
    defer alloc.free(dest_file_utf8);
    const dest_file_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dest_file_utf8);
    defer alloc.free(dest_file_w);

    const actual_sha256 = try downloadUrlToFile(alloc, job.asset_url, dest_file_w, 256 * 1024 * 1024);
    if (!std.mem.eql(u8, &actual_sha256, &expected_sha256)) {
        _ = DeleteFileW(dest_file_w);
        return error.Sha256Mismatch;
    }

    switch (job.install_kind) {
        .installer => {
            apply.staged_path_w = try alloc.dupeSentinel(u16, dest_file_w, 0);
            apply.success = true;
        },
        .portable => {
            const extract_dir_utf8 = try std.fmt.allocPrint(alloc, "{s}\\extracted", .{temp_dir_utf8});
            defer alloc.free(extract_dir_utf8);

            try extractZipArchive(alloc, dest_file_utf8, extract_dir_utf8);

            const staged_root_utf8 = try std.fmt.allocPrint(alloc, "{s}\\ghostty", .{extract_dir_utf8});
            defer alloc.free(staged_root_utf8);
            const staged_exe_utf8 = try std.fmt.allocPrint(alloc, "{s}\\bin\\ghostty.exe", .{staged_root_utf8});
            defer alloc.free(staged_exe_utf8);
            const staged_exe_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, staged_exe_utf8);
            defer alloc.free(staged_exe_w);

            const attrs = windows.exp.kernel32.GetFileAttributesW(staged_exe_w);
            if (attrs == windows.INVALID_FILE_ATTRIBUTES or (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0) {
                return error.InvalidPortableArchiveLayout;
            }

            apply.staged_path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, staged_root_utf8);
            apply.success = true;
        },
        .unknown => return error.UnsupportedInstallKind,
    }
}

fn downloadUrlBytes(alloc: Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    if (!isAllowedReleaseAssetUrl(url)) return error.DisallowedAssetUrl;
    const parsed_url = try parseHttpsUrl(url);
    const http = loadWinHttp() orelse return error.WinHttpLoadFailed;

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, parsed_url.host);
    defer alloc.free(host_w);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, parsed_url.path);
    defer alloc.free(path_w);

    const session = http.WinHttpOpen(
        L("Ghostty-Windows-Updater/1.0"),
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        null,
        null,
        0,
    ) orelse return error.WinHttpOpenFailed;
    defer _ = http.WinHttpCloseHandle(session);

    _ = http.WinHttpSetTimeouts(session, 10000, 15000, 15000, 30000);

    const connect = http.WinHttpConnect(
        session,
        host_w,
        INTERNET_DEFAULT_HTTPS_PORT,
        0,
    ) orelse return error.WinHttpConnectFailed;
    defer _ = http.WinHttpCloseHandle(connect);

    const request = http.WinHttpOpenRequest(
        connect,
        L("GET"),
        path_w,
        null,
        null,
        null,
        WINHTTP_FLAG_SECURE,
    ) orelse return error.WinHttpOpenRequestFailed;
    defer _ = http.WinHttpCloseHandle(request);

    if (!http.WinHttpSendRequest(
        request,
        null,
        0,
        null,
        0,
        0,
        0,
    ).toBool()) return error.WinHttpSendRequestFailed;

    if (!http.WinHttpReceiveResponse(request, null).toBool()) {
        return error.WinHttpReceiveResponseFailed;
    }

    var status_code: c.DWORD = 0;
    var status_size: c.DWORD = @sizeOf(c.DWORD);
    if (!http.WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &status_code,
        &status_size,
        null,
    ).toBool() or status_code != 200) {
        return error.HttpStatusNotOk;
    }

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);

    var buf: [8192]u8 = undefined;
    while (true) {
        var read_bytes: c.DWORD = 0;
        if (!http.WinHttpReadData(request, &buf, buf.len, &read_bytes).toBool()) {
            return error.WinHttpReadDataFailed;
        }
        if (read_bytes == 0) break;
        if (body.items.len + read_bytes > max_bytes) return error.ResponseTooLarge;
        try body.appendSlice(alloc, buf[0..read_bytes]);
    }

    return try body.toOwnedSlice(alloc);
}

fn downloadUrlToFile(
    alloc: Allocator,
    url: []const u8,
    dest_path_w: [:0]const u16,
    max_bytes: usize,
) ![32]u8 {
    if (!isAllowedReleaseAssetUrl(url)) return error.DisallowedAssetUrl;
    const parsed_url = try parseHttpsUrl(url);
    const http = loadWinHttp() orelse return error.WinHttpLoadFailed;

    const host_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, parsed_url.host);
    defer alloc.free(host_w);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, parsed_url.path);
    defer alloc.free(path_w);

    const session = http.WinHttpOpen(
        L("Ghostty-Windows-Updater/1.0"),
        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        null,
        null,
        0,
    ) orelse return error.WinHttpOpenFailed;
    defer _ = http.WinHttpCloseHandle(session);

    _ = http.WinHttpSetTimeouts(session, 10000, 15000, 15000, 60000);

    const connect = http.WinHttpConnect(
        session,
        host_w,
        INTERNET_DEFAULT_HTTPS_PORT,
        0,
    ) orelse return error.WinHttpConnectFailed;
    defer _ = http.WinHttpCloseHandle(connect);

    const request = http.WinHttpOpenRequest(
        connect,
        L("GET"),
        path_w,
        null,
        null,
        null,
        WINHTTP_FLAG_SECURE,
    ) orelse return error.WinHttpOpenRequestFailed;
    defer _ = http.WinHttpCloseHandle(request);

    if (!http.WinHttpSendRequest(
        request,
        null,
        0,
        null,
        0,
        0,
        0,
    ).toBool()) return error.WinHttpSendRequestFailed;

    if (!http.WinHttpReceiveResponse(request, null).toBool()) {
        return error.WinHttpReceiveResponseFailed;
    }

    var status_code: c.DWORD = 0;
    var status_size: c.DWORD = @sizeOf(c.DWORD);
    if (!http.WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        null,
        &status_code,
        &status_size,
        null,
    ).toBool() or status_code != 200) {
        return error.HttpStatusNotOk;
    }

    const file_handle = windows.exp.kernel32.CreateFileW(
        dest_path_w,
        windows.GENERIC_WRITE,
        0,
        null,
        windows.CREATE_ALWAYS,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (file_handle == windows.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
    var file_closed = false;
    defer if (!file_closed) {
        _ = windows.exp.kernel32.CloseHandle(file_handle);
    };
    errdefer {
        if (!file_closed) {
            _ = windows.exp.kernel32.CloseHandle(file_handle);
            file_closed = true;
        }
        _ = DeleteFileW(dest_path_w);
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total_bytes: usize = 0;
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        var read_bytes: c.DWORD = 0;
        if (!http.WinHttpReadData(request, &buf, buf.len, &read_bytes).toBool()) {
            return error.WinHttpReadDataFailed;
        }
        if (read_bytes == 0) break;
        total_bytes += read_bytes;
        if (total_bytes > max_bytes) return error.ResponseTooLarge;

        hasher.update(buf[0..read_bytes]);

        var written: c.DWORD = 0;
        if (!windows.exp.kernel32.WriteFile(
            file_handle,
            &buf,
            read_bytes,
            &written,
            null,
        ).toBool() or written != read_bytes) {
            return error.WriteFileFailed;
        }
    }

    if (total_bytes == 0) return error.EmptyDownload;
    return hasher.finalResult();
}

fn extractZipArchive(alloc: Allocator, zip_path_utf8: []const u8, dest_dir_utf8: []const u8) !void {
    const escaped_zip = try escapePowerShellSingleQuoted(alloc, zip_path_utf8);
    defer alloc.free(escaped_zip);
    const escaped_dest = try escapePowerShellSingleQuoted(alloc, dest_dir_utf8);
    defer alloc.free(escaped_dest);

    const ps_path = try systemPowerShellPath(alloc);
    defer alloc.free(ps_path);

    const cmd_utf8 = try std.fmt.allocPrint(
        alloc,
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force\"",
        .{ escaped_zip, escaped_dest },
    );
    defer alloc.free(cmd_utf8);

    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8);
    defer alloc.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (!windows.exp.kernel32.CreateProcessW(
        ps_path.ptr,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    ).toBool()) return error.ExtractProcessSpawnFailed;
    defer _ = windows.exp.kernel32.CloseHandle(pi.hProcess);
    defer _ = windows.exp.kernel32.CloseHandle(pi.hThread);

    const wait_res = windows.exp.kernel32.WaitForSingleObject(pi.hProcess, 120_000);
    if (wait_res != 0) return error.ExtractProcessTimeout;

    var exit_code: c.DWORD = 1;
    if (!windows.exp.kernel32.GetExitCodeProcess(pi.hProcess, &exit_code).toBool() or exit_code != 0) {
        return error.ExtractProcessFailed;
    }
}

pub fn handleApply(app: *App, lparam: c.LPARAM) void {
    const alloc = app.core_app.alloc;
    if (lparam == 0) return;
    const apply: *ApplyResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
    defer apply.deinit(alloc);

    if (app.quitting) return;
    const owner: ?c.HWND = if (app.activeWindow()) |w| w.hwnd else null;

    if (!apply.success or apply.staged_path_w == null) {
        promptOpenReleaseOnFailure(alloc, owner, apply.html_url, apply.error_msg);
        return;
    }

    const applied = switch (apply.install_kind) {
        .installer => launchInstallerUpgrade(alloc, apply.staged_path_w.?),
        .portable => launchPortableUpgrade(alloc, apply.staged_path_w.?, apply.temp_dir_w),
        .unknown => false,
    };

    if (applied) {
        app.quit();
    } else {
        promptOpenReleaseOnFailure(alloc, owner, apply.html_url, "Failed to launch installer");
    }
}

fn promptOpenReleaseOnFailure(
    alloc: Allocator,
    owner: ?c.HWND,
    html_url: []const u8,
    reason: ?[]const u8,
) void {
    const detail = reason orelse "unknown error";
    const msg = std.fmt.allocPrint(
        alloc,
        "Automatic update could not be completed ({s}).\n\nWould you like to open the release page to download the update manually?",
        .{detail},
    ) catch return;
    defer alloc.free(msg);

    const main_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Update Failed"))) catch return;
    defer alloc.free(main_w);
    const content_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, msg) catch return;
    defer alloc.free(content_w);
    const yes_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Open Releases Page"))) catch return;
    defer alloc.free(yes_w);
    const no_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, std.mem.span(i18n._("Cancel"))) catch return;
    defer alloc.free(no_w);

    if (dialogs.confirm(owner, .{
        .main = main_w,
        .content = content_w,
        .yes = yes_w,
        .no = no_w,
        .icon = .warning,
    })) {
        internal_os.open(.html, html_url) catch {};
    }
}

fn launchInstallerUpgrade(alloc: Allocator, setup_exe_w: [:0]const u16) bool {
    const setup_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, setup_exe_w) catch return false;
    defer alloc.free(setup_utf8);

    const cmd_utf8 = std.fmt.allocPrint(
        alloc,
        "\"{s}\" /SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /NOCANCEL /SP-",
        .{setup_utf8},
    ) catch return false;
    defer alloc.free(cmd_utf8);

    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return false;
    defer alloc.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    if (!windows.exp.kernel32.CreateProcessW(
        @constCast(setup_exe_w.ptr),
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        0,
        null,
        null,
        &si,
        &pi,
    ).toBool()) {
        log.warn("failed to launch setup installer for auto-update", .{});
        return false;
    }
    _ = windows.exp.kernel32.CloseHandle(pi.hProcess);
    _ = windows.exp.kernel32.CloseHandle(pi.hThread);
    return true;
}

fn launchPortableUpgrade(
    alloc: Allocator,
    staged_root_w: [:0]const u16,
    temp_dir_w: ?[:0]const u16,
) bool {
    var exe_buf: [2048]u16 = undefined;
    const len = windows.exp.kernel32.GetModuleFileNameW(null, &exe_buf, exe_buf.len - 8);
    if (len == 0 or len >= exe_buf.len - 8) return false;
    exe_buf[len] = 0;

    const exe_slice = exe_buf[0..len];
    const bin_sep = std.mem.lastIndexOfAny(u16, exe_slice, &.{ '\\', '/' }) orelse return false;
    const bin_dir = exe_slice[0..bin_sep];
    const root_sep = std.mem.lastIndexOfAny(u16, bin_dir, &.{ '\\', '/' }) orelse return false;
    const root_dir_w = bin_dir[0..root_sep];

    var old_exe_buf: [2056]u16 = undefined;
    const suffix = L(".old");
    @memcpy(old_exe_buf[0..len], exe_slice);
    @memcpy(old_exe_buf[len .. len + suffix.len], suffix);
    old_exe_buf[len + suffix.len] = 0;

    const ps_path = systemPowerShellPath(alloc) catch return false;
    defer alloc.free(ps_path);

    const exe_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, exe_slice) catch return false;
    defer alloc.free(exe_utf8);
    const root_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, root_dir_w) catch return false;
    defer alloc.free(root_utf8);
    const staged_utf8 = std.unicode.utf16LeToUtf8Alloc(alloc, staged_root_w) catch return false;
    defer alloc.free(staged_utf8);

    const escaped_exe = escapePowerShellSingleQuoted(alloc, exe_utf8) catch return false;
    defer alloc.free(escaped_exe);
    const escaped_root = escapePowerShellSingleQuoted(alloc, root_utf8) catch return false;
    defer alloc.free(escaped_root);
    const escaped_staged = escapePowerShellSingleQuoted(alloc, staged_utf8) catch return false;
    defer alloc.free(escaped_staged);

    const temp_utf8 = if (temp_dir_w) |td|
        std.unicode.utf16LeToUtf8Alloc(alloc, td) catch null
    else
        null;
    defer if (temp_utf8) |t| alloc.free(t);
    const escaped_temp = if (temp_utf8) |t|
        escapePowerShellSingleQuoted(alloc, t) catch null
    else
        null;
    defer if (escaped_temp) |t| alloc.free(t);

    const pid = windows.GetCurrentProcessId();
    const cleanup_clause = if (escaped_temp) |t|
        std.fmt.allocPrint(alloc, "Remove-Item -LiteralPath '{s}' -Recurse -Force -ErrorAction SilentlyContinue; ", .{t}) catch return false
    else
        alloc.dupe(u8, "") catch return false;
    defer alloc.free(cleanup_clause);

    const cmd_utf8 = std.fmt.allocPrint(
        alloc,
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"Wait-Process -Id {d} -Timeout 30 -ErrorAction SilentlyContinue; if (-not (Get-Process -Id {d} -ErrorAction SilentlyContinue)) {{ Get-ChildItem -LiteralPath '{s}' -Force | Copy-Item -Destination '{s}' -Recurse -Force; {s}Start-Process -FilePath '{s}' }}\"",
        .{ pid, pid, escaped_staged, escaped_root, cleanup_clause, escaped_exe },
    ) catch return false;
    defer alloc.free(cmd_utf8);

    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return false;
    defer alloc.free(cmd_w);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = undefined;

    const renamed = MoveFileExW(@ptrCast(&exe_buf), @ptrCast(&old_exe_buf), MOVEFILE_REPLACE_EXISTING).toBool();

    if (!windows.exp.kernel32.CreateProcessW(
        ps_path.ptr,
        cmd_w.ptr,
        null,
        null,
        windows.FALSE,
        CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    ).toBool()) {
        if (renamed) {
            _ = MoveFileExW(@ptrCast(&old_exe_buf), @ptrCast(&exe_buf), MOVEFILE_REPLACE_EXISTING);
        }
        log.warn("failed to launch portable upgrade helper process", .{});
        return false;
    }
    _ = windows.exp.kernel32.CloseHandle(pi.hProcess);
    _ = windows.exp.kernel32.CloseHandle(pi.hThread);
    return true;
}

pub fn isNewerVersion(current_raw: []const u8, latest_raw: []const u8) bool {
    const cur = normalizeVersion(current_raw);
    const lat = normalizeVersion(latest_raw);
    if (std.mem.eql(u8, cur, lat)) return false;

    const cur_sem = parseCoreVersion(cur) orelse return false;
    const lat_sem = parseCoreVersion(lat) orelse return false;

    if (cur_sem.major == lat_sem.major and
        cur_sem.minor == lat_sem.minor and
        cur_sem.patch == lat_sem.patch)
    {
        if (extractWindowsGitSha(cur_sem.pre) != null or extractWindowsGitSha(lat_sem.pre) != null) {
            return !std.mem.eql(u8, cur_sem.pre orelse "", lat_sem.pre orelse "");
        }
    }

    return switch (cur_sem.order(lat_sem)) {
        .lt => true,
        .gt => false,
        .eq => false,
    };
}

fn extractWindowsGitSha(pre: ?[]const u8) ?[]const u8 {
    const p = pre orelse return null;
    if (!std.mem.startsWith(u8, p, "windows.")) return null;
    const id = p["windows.".len..];
    if (id.len < 7) return null;
    for (id) |ch| {
        if (!std.ascii.isHex(ch)) return null;
    }
    return id;
}

fn normalizeVersion(v: []const u8) []const u8 {
    var s = std.mem.trim(u8, v, " \t\r\n");
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (std.mem.startsWith(u8, s, "windows-v")) {
        s = s["windows-v".len..];
    } else if (std.mem.startsWith(u8, s, "windows-")) {
        s = s["windows-".len..];
    }
    return s;
}

fn parseCoreVersion(v: []const u8) ?std.SemanticVersion {
    if (std.SemanticVersion.parse(v)) |sem| return sem else |_| {}
    const end = std.mem.indexOfAny(u8, v, "-+") orelse v.len;
    return std.SemanticVersion.parse(v[0..end]) catch null;
}

test "updater: isNewerVersion" {
    const testing = std.testing;
    try testing.expect(isNewerVersion("1.2.0", "v1.3.0"));
    try testing.expect(isNewerVersion("1.3.0-dev", "v1.3.1-windows.1"));
    try testing.expect(isNewerVersion("1.3.1-dev", "v1.3.1"));
    try testing.expect(isNewerVersion("1.3.1-windows.1", "v1.3.1-windows.2"));
    try testing.expect(isNewerVersion("1.3.1-windows.1", "windows-v1.3.1-windows.2"));
    try testing.expect(isNewerVersion("1.4.1-windows.15400.gffffff0", "windows-v1.4.1-windows.15401.g0123456"));
    try testing.expect(!isNewerVersion("1.4.1-windows.15401.g0123456", "windows-v1.4.1-windows.15400.gffffff0"));
    try testing.expect(isNewerVersion("1.4.1-windows.9abcdef", "windows-v1.4.1-windows.1234567"));
    try testing.expect(!isNewerVersion("1.4.1-windows.1234567", "windows-v1.4.1-windows.1234567"));
    try testing.expect(!isNewerVersion("1.3.1", "v1.3.1"));
    try testing.expect(!isNewerVersion("1.3.2-dev+abcdef", "v1.3.1"));
    try testing.expect(isSafeHttpsUrl("https://github.com/RecursiveFunctions/ghostty-windows/releases/tag/v1.4.1"));
    try testing.expect(!isSafeHttpsUrl("file:///C:/Windows/System32/calc.exe"));
}

test "updater: URL validation and parsing" {
    const testing = std.testing;
    try testing.expect(isAllowedReleaseAssetUrl(
        "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1/Ghostty-Windows-Setup-x64.exe",
    ));
    try testing.expect(isAllowedReleaseAssetUrl(
        "https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345/Ghostty-Windows-x64.zip",
    ));
    try testing.expect(!isAllowedReleaseAssetUrl(
        "https://evil.example.com/Ghostty-Windows-Setup-x64.exe",
    ));
    try testing.expect(!isAllowedReleaseAssetUrl(
        "http://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1/Ghostty-Windows-Setup-x64.exe",
    ));

    const parsed = try parseHttpsUrl(
        "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1/SHA256SUMS.txt",
    );
    try testing.expectEqualStrings("github.com", parsed.host);
    try testing.expectEqualStrings(
        "/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1/SHA256SUMS.txt",
        parsed.path,
    );
}

test "updater: parseReleaseJson and parseSha256Sums" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const sample_json =
        \\{
        \\  "tag_name": "windows-v1.4.1-windows.2",
        \\  "html_url": "https://github.com/RecursiveFunctions/ghostty-windows/releases/tag/windows-v1.4.1-windows.2",
        \\  "assets": [
        \\    {
        \\      "name": "Ghostty-Windows-Setup-x64.exe",
        \\      "browser_download_url": "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1-windows.2/Ghostty-Windows-Setup-x64.exe"
        \\    },
        \\    {
        \\      "name": "Ghostty-Windows-x64.zip",
        \\      "browser_download_url": "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1-windows.2/Ghostty-Windows-x64.zip"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS.txt",
        \\      "browser_download_url": "https://github.com/RecursiveFunctions/ghostty-windows/releases/download/windows-v1.4.1-windows.2/SHA256SUMS.txt"
        \\    }
        \\  ]
        \\}
    ;

    var info = try parseReleaseJson(alloc, sample_json);
    defer info.deinit(alloc);

    try testing.expectEqualStrings("windows-v1.4.1-windows.2", info.tag_name);
    try testing.expect(info.setup_url != null);
    try testing.expect(info.zip_url != null);
    try testing.expect(info.sha256_url != null);

    var expected_setup_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("dummy-setup-binary", &expected_setup_hash, .{});
    const hex_setup = std.fmt.bytesToHex(expected_setup_hash, .lower);

    const sums_content = try std.fmt.allocPrint(
        alloc,
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  Ghostty-Windows-x64.zip\r\n{s}  Ghostty-Windows-Setup-x64.exe\r\n",
        .{hex_setup},
    );
    defer alloc.free(sums_content);

    const parsed_digest = parseSha256Sums(sums_content, setup_asset_name) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &expected_setup_hash, &parsed_digest);
    try testing.expect(parseSha256Sums(sums_content, "nonexistent.exe") == null);

    const escaped = try escapePowerShellSingleQuoted(alloc, "C:\\Users\\O'Connor\\Ghostty");
    defer alloc.free(escaped);
    try testing.expectEqualStrings("C:\\Users\\O''Connor\\Ghostty", escaped);
}
