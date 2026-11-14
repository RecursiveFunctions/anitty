const BellAudio = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const GUID = windows.GUID;
const c = @import("c.zig");
const HRESULT = c.HRESULT;
const clipboard = @import("clipboard.zig");

const log = std.log.scoped(.win32);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const CLSCTX_INPROC_SERVER: c.DWORD = 0x1;
const MF_VERSION: c.DWORD = 0x00020070;
const MFSTARTUP_LITE: c.DWORD = 0x1;
const MF_MEDIA_ENGINE_AUDIOONLY: c.DWORD = 0x1;
const AudioCategory_Alerts: u32 = 4;
const MF_MEDIA_ENGINE_EVENT_LOADEDDATA: c.DWORD = 12;
const MF_MEDIA_ENGINE_EVENT_CANPLAY: c.DWORD = 14;
const MF_MEDIA_ENGINE_EVENT_ERROR: c.DWORD = 4;

const IID_IUnknown: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IID_IMFMediaEngineNotify: GUID = .{
    .Data1 = 0xFEE7C112,
    .Data2 = 0xE776,
    .Data3 = 0x42B5,
    .Data4 = .{ 0x9B, 0xBF, 0x00, 0x48, 0x52, 0x4E, 0x2B, 0xD5 },
};

const CLSID_MFMediaEngineClassFactory: GUID = .{
    .Data1 = 0xB44392DA,
    .Data2 = 0x499B,
    .Data3 = 0x446B,
    .Data4 = .{ 0xA4, 0xCB, 0x00, 0x5F, 0xEA, 0xD0, 0xE6, 0xD5 },
};

const IID_IMFMediaEngineClassFactory: GUID = .{
    .Data1 = 0x4D645ACE,
    .Data2 = 0x26AA,
    .Data3 = 0x4688,
    .Data4 = .{ 0x9B, 0xE1, 0xDF, 0x35, 0x16, 0x99, 0x0B, 0x93 },
};

const MF_MEDIA_ENGINE_CALLBACK: GUID = .{
    .Data1 = 0xC60381B8,
    .Data2 = 0x83A4,
    .Data3 = 0x41F8,
    .Data4 = .{ 0xA3, 0xD0, 0xDE, 0x05, 0x07, 0x68, 0x49, 0xA9 },
};

const MF_MEDIA_ENGINE_AUDIO_CATEGORY: GUID = .{
    .Data1 = 0xC8D4C51D,
    .Data2 = 0x350E,
    .Data3 = 0x41F2,
    .Data4 = .{ 0xBA, 0x46, 0xFA, 0xEB, 0xBB, 0x08, 0x57, 0xF6 },
};

extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: c.DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

extern "kernel32" fn GetFileAttributesW(name: c.LPCWSTR) callconv(.winapi) c.DWORD;
const INVALID_FILE_ATTRIBUTES: c.DWORD = 0xFFFF_FFFF;

const BSTR = [*:0]u16;
const MFStartupFn = *const fn (c.DWORD, c.DWORD) callconv(.winapi) HRESULT;
const MFShutdownFn = *const fn () callconv(.winapi) HRESULT;
const MFCreateAttributesFn = *const fn (*?*IMFAttributes, u32) callconv(.winapi) HRESULT;
const SysAllocStringFn = *const fn (c.LPCWSTR) callconv(.winapi) ?BSTR;
const SysFreeStringFn = *const fn (?BSTR) callconv(.winapi) void;

const IMFAttributes = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFAttributes) callconv(.winapi) u32,
        GetItem: *const anyopaque,
        GetItemType: *const anyopaque,
        CompareItem: *const anyopaque,
        Compare: *const anyopaque,
        GetUINT32: *const anyopaque,
        GetUINT64: *const anyopaque,
        GetDouble: *const anyopaque,
        GetGUID: *const anyopaque,
        GetStringLength: *const anyopaque,
        GetString: *const anyopaque,
        GetAllocatedString: *const anyopaque,
        GetBlobSize: *const anyopaque,
        GetBlob: *const anyopaque,
        GetAllocatedBlob: *const anyopaque,
        GetUnknown: *const anyopaque,
        SetItem: *const anyopaque,
        DeleteItem: *const anyopaque,
        DeleteAllItems: *const anyopaque,
        SetUINT32: *const fn (*IMFAttributes, *const GUID, u32) callconv(.winapi) HRESULT,
        SetUINT64: *const anyopaque,
        SetDouble: *const anyopaque,
        SetGUID: *const anyopaque,
        SetString: *const anyopaque,
        SetBlob: *const anyopaque,
        SetUnknown: *const fn (*IMFAttributes, *const GUID, *anyopaque) callconv(.winapi) HRESULT,
    };
};

const IMFMediaEngineClassFactory = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFMediaEngineClassFactory) callconv(.winapi) u32,
        CreateInstance: *const fn (
            *IMFMediaEngineClassFactory,
            c.DWORD,
            *IMFAttributes,
            *?*IMFMediaEngine,
        ) callconv(.winapi) HRESULT,
    };
};

const IMFMediaEngine = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFMediaEngine) callconv(.winapi) u32,
        GetError: *const anyopaque,
        SetErrorCode: *const anyopaque,
        SetSourceElements: *const anyopaque,
        SetSource: *const fn (*IMFMediaEngine, ?BSTR) callconv(.winapi) HRESULT,
        GetCurrentSource: *const anyopaque,
        GetNetworkState: *const anyopaque,
        GetPreload: *const anyopaque,
        SetPreload: *const anyopaque,
        GetBuffered: *const anyopaque,
        Load: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        CanPlayType: *const anyopaque,
        GetReadyState: *const anyopaque,
        IsSeeking: *const anyopaque,
        GetCurrentTime: *const anyopaque,
        SetCurrentTime: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        GetStartTime: *const anyopaque,
        GetDuration: *const anyopaque,
        IsPaused: *const anyopaque,
        GetDefaultPlaybackRate: *const anyopaque,
        SetDefaultPlaybackRate: *const anyopaque,
        GetPlaybackRate: *const anyopaque,
        SetPlaybackRate: *const anyopaque,
        GetPlayed: *const anyopaque,
        GetSeekable: *const anyopaque,
        IsEnded: *const anyopaque,
        GetAutoPlay: *const anyopaque,
        SetAutoPlay: *const fn (*IMFMediaEngine, c.BOOL) callconv(.winapi) HRESULT,
        GetLoop: *const anyopaque,
        SetLoop: *const anyopaque,
        Play: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        Pause: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
        GetMuted: *const anyopaque,
        SetMuted: *const anyopaque,
        GetVolume: *const anyopaque,
        SetVolume: *const fn (*IMFMediaEngine, f64) callconv(.winapi) HRESULT,
        HasVideo: *const anyopaque,
        HasAudio: *const anyopaque,
        GetNativeVideoSize: *const anyopaque,
        GetVideoAspectRatio: *const anyopaque,
        Shutdown: *const fn (*IMFMediaEngine) callconv(.winapi) HRESULT,
    };
};

const NotifyVTable = extern struct {
    QueryInterface: *const fn (*BellAudio, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*BellAudio) callconv(.winapi) u32,
    Release: *const fn (*BellAudio) callconv(.winapi) u32,
    EventNotify: *const fn (*BellAudio, c.DWORD, usize, c.DWORD) callconv(.winapi) HRESULT,
};

const notify_vtable: NotifyVTable = .{
    .QueryInterface = notifyQueryInterface,
    .AddRef = notifyAddRef,
    .Release = notifyRelease,
    .EventNotify = notifyEvent,
};

lpVtbl: *const NotifyVTable = &notify_vtable,
mfplat_mod: ?c.HMODULE = null,
oleaut_mod: ?c.HMODULE = null,
mf_started: bool = false,
mf_failed: bool = false,
mf_shutdown: ?MFShutdownFn = null,
sys_alloc_string: ?SysAllocStringFn = null,
sys_free_string: ?SysFreeStringFn = null,
engine: ?*IMFMediaEngine = null,
current_path: ?[]u8 = null,
play_pending: bool = false,
required_current: bool = false,

pub fn deinit(self: *BellAudio, alloc: Allocator) void {
    if (self.current_path) |p| {
        alloc.free(p);
        self.current_path = null;
    }
    if (self.engine) |eng| {
        self.engine = null;
        _ = eng.lpVtbl.Shutdown(eng);
        _ = eng.lpVtbl.Release(eng);
    }
    if (self.mf_started) {
        self.mf_started = false;
        if (self.mf_shutdown) |shutdown| _ = shutdown();
    }
    if (self.mfplat_mod) |m| {
        self.mfplat_mod = null;
        _ = c.FreeLibrary(m);
    }
    if (self.oleaut_mod) |m| {
        self.oleaut_mod = null;
        _ = c.FreeLibrary(m);
    }
}

pub fn ring(
    self: *BellAudio,
    alloc: Allocator,
    path: [:0]const u8,
    required: bool,
    volume: f64,
) bool {
    if (path.len == 0) return false;
    const wide = clipboard.utf16FromUtf8(alloc, path) catch return false;
    defer alloc.free(wide);

    if (GetFileAttributesW(wide.ptr) == INVALID_FILE_ATTRIBUTES) {
        if (required) {
            log.warn("bell-audio-path does not exist or is inaccessible: {s}", .{path});
        }
        return false;
    }

    const eng = self.ensureEngine() orelse return false;
    const vol = std.math.clamp(volume, 0.0, 1.0);
    _ = eng.lpVtbl.SetVolume(eng, vol);
    self.required_current = required;

    if (self.current_path) |cur| {
        if (std.mem.eql(u8, cur, path)) {
            _ = eng.lpVtbl.SetCurrentTime(eng, 0.0);
            _ = eng.lpVtbl.Play(eng);
            return true;
        }
        alloc.free(cur);
        self.current_path = null;
    }

    const alloc_bstr = self.sys_alloc_string orelse return false;
    const free_bstr = self.sys_free_string orelse return false;
    const bstr = alloc_bstr(wide.ptr) orelse return false;
    defer free_bstr(bstr);

    self.play_pending = true;
    _ = eng.lpVtbl.SetAutoPlay(eng, .TRUE);
    if (eng.lpVtbl.SetSource(eng, bstr) < 0) {
        self.play_pending = false;
        return false;
    }
    self.current_path = alloc.dupe(u8, path) catch null;
    _ = eng.lpVtbl.Load(eng);
    _ = eng.lpVtbl.Play(eng);
    return true;
}

fn ensureEngine(self: *BellAudio) ?*IMFMediaEngine {
    if (self.engine) |eng| return eng;
    if (self.mf_failed) return null;

    const mfplat = c.LoadLibraryExW(L("mfplat.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
        self.mf_failed = true;
        return null;
    };
    self.mfplat_mod = mfplat;

    const oleaut = c.LoadLibraryExW(L("oleaut32.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
        self.mf_failed = true;
        return null;
    };
    self.oleaut_mod = oleaut;

    const startup: MFStartupFn = @ptrCast(c.GetProcAddress(mfplat, "MFStartup") orelse {
        self.mf_failed = true;
        return null;
    });
    self.mf_shutdown = @ptrCast(c.GetProcAddress(mfplat, "MFShutdown") orelse {
        self.mf_failed = true;
        return null;
    });
    const create_attrs: MFCreateAttributesFn = @ptrCast(c.GetProcAddress(mfplat, "MFCreateAttributes") orelse {
        self.mf_failed = true;
        return null;
    });
    self.sys_alloc_string = @ptrCast(c.GetProcAddress(oleaut, "SysAllocString") orelse {
        self.mf_failed = true;
        return null;
    });
    self.sys_free_string = @ptrCast(c.GetProcAddress(oleaut, "SysFreeString") orelse {
        self.mf_failed = true;
        return null;
    });

    if (startup(MF_VERSION, MFSTARTUP_LITE) < 0) {
        self.mf_failed = true;
        return null;
    }
    self.mf_started = true;

    var raw_factory: ?*anyopaque = null;
    if (CoCreateInstance(
        &CLSID_MFMediaEngineClassFactory,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IMFMediaEngineClassFactory,
        &raw_factory,
    ) < 0 or raw_factory == null) {
        self.mf_failed = true;
        return null;
    }
    const factory: *IMFMediaEngineClassFactory = @ptrCast(@alignCast(raw_factory.?));
    defer _ = factory.lpVtbl.Release(factory);

    var attrs_opt: ?*IMFAttributes = null;
    if (create_attrs(&attrs_opt, 2) < 0 or attrs_opt == null) {
        self.mf_failed = true;
        return null;
    }
    const attrs = attrs_opt.?;
    defer _ = attrs.lpVtbl.Release(attrs);

    _ = attrs.lpVtbl.SetUnknown(attrs, &MF_MEDIA_ENGINE_CALLBACK, self);
    _ = attrs.lpVtbl.SetUINT32(attrs, &MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_Alerts);

    var eng: ?*IMFMediaEngine = null;
    if (factory.lpVtbl.CreateInstance(factory, MF_MEDIA_ENGINE_AUDIOONLY, attrs, &eng) < 0 or eng == null) {
        self.mf_failed = true;
        return null;
    }
    self.engine = eng;
    return eng;
}

fn notifyQueryInterface(self: *BellAudio, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&IID_IUnknown)) or
        std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&IID_IMFMediaEngineNotify)))
    {
        ppv.* = self;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

fn notifyAddRef(_: *BellAudio) callconv(.winapi) u32 {
    return 1;
}

fn notifyRelease(_: *BellAudio) callconv(.winapi) u32 {
    return 1;
}

fn notifyEvent(
    self: *BellAudio,
    event: c.DWORD,
    param1: usize,
    param2: c.DWORD,
) callconv(.winapi) HRESULT {
    switch (event) {
        MF_MEDIA_ENGINE_EVENT_LOADEDDATA, MF_MEDIA_ENGINE_EVENT_CANPLAY => {
            if (self.play_pending) {
                self.play_pending = false;
                if (self.engine) |eng| {
                    _ = eng.lpVtbl.Play(eng);
                }
            }
        },
        MF_MEDIA_ENGINE_EVENT_ERROR => {
            self.play_pending = false;
            if (self.required_current) {
                log.warn("bell audio playback error err={} hr={x}", .{ param1, param2 });
            }
        },
        else => {},
    }
    return S_OK;
}

pub fn silentWav() [44]u8 {
    return .{
        'R',  'I',  'F',  'F',
        36,   0,    0,    0,
        'W',  'A',  'V',  'E',
        'f',  'm',  't',  ' ',
        16,   0,    0,    0,
        1,    0,    1,    0,
        0x44, 0xAC, 0,    0,
        0x88, 0x58, 0x01, 0,
        2,    0,    16,   0,
        'd',  'a',  't',  'a',
        0,    0,    0,    0,
    };
}

test "silentWav header" {
    const testing = std.testing;
    const wav = silentWav();
    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqualStrings("fmt ", wav[12..16]);
    try testing.expectEqualStrings("data", wav[36..40]);
    try testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, wav[4..8], .little));
    try testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, wav[24..28], .little));
}
