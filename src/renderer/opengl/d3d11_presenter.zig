//! D3D11 / DXGI Flip-Model + Microsoft WARP Software Fallback Presenter.
//! Provides zero-dependency Zig COM vtable bindings for ID3D11Device,
//! ID3D11DeviceContext, IDXGISwapChain1, and WGL_NV_DX_interop2.
//!
//! Modes (selected via GHOSTTY_WIN32_PRESENTER=wgl|d3d11|warp or automatic):
//! - Hardware D3D11 + WGL_NV_DX_interop2 shared texture when supported
//! - Microsoft WARP software rasterizer (D3D_DRIVER_TYPE_WARP) for GPU-less
//!   VMs, Windows Sandbox, and Remote Desktop (RDP) sessions.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const log = std.log.scoped(.d3d11_presenter);

pub const HRESULT = c_long;
pub const UINT = u32;
pub const DWORD = u32;
pub const BOOL = windows.BOOL;
pub const HWND = windows.HWND;
pub const HANDLE = windows.HANDLE;
pub const HMODULE = windows.HMODULE;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const IID_IDXGIDevice = GUID{
    .Data1 = 0x54ec77fa,
    .Data2 = 0x1377,
    .Data3 = 0x44e6,
    .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};

pub const IID_IDXGIFactory2 = GUID{
    .Data1 = 0x50c83a1c,
    .Data2 = 0xe072,
    .Data3 = 0x4c48,
    .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};

pub const IID_ID3D11Texture2D = GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

pub const D3D_DRIVER_TYPE_UNKNOWN: u32 = 0;
pub const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
pub const D3D_DRIVER_TYPE_WARP: u32 = 5;

pub const D3D_FEATURE_LEVEL_11_1: u32 = 0xb100;
pub const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;
pub const D3D_FEATURE_LEVEL_10_1: u32 = 0xa100;
pub const D3D_FEATURE_LEVEL_10_0: u32 = 0xa000;

pub const D3D11_SDK_VERSION: u32 = 7;
pub const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;

pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    Format: u32 = DXGI_FORMAT_B8G8R8A8_UNORM,
    Stereo: BOOL = .FALSE,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32 = DXGI_USAGE_RENDER_TARGET_OUTPUT,
    BufferCount: u32 = 2,
    Scaling: u32 = DXGI_SCALING_STRETCH,
    SwapEffect: u32 = DXGI_SWAP_EFFECT_FLIP_DISCARD,
    AlphaMode: u32 = DXGI_ALPHA_MODE_IGNORE,
    Flags: u32 = 0,
};

pub const D3D11_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32 = 0,
    right: u32,
    bottom: u32,
    back: u32 = 1,
};

pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    pub fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
        Release: *const fn (*IDXGIAdapter) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const fn (*IDXGIAdapter, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDXGIAdapter) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDXGIDevice, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIDevice) callconv(.winapi) u32,
        Release: *const fn (*IDXGIDevice) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        GetAdapter: *const fn (*IDXGIDevice, *?*IDXGIAdapter) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDXGIDevice) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (*IDXGISwapChain1, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGISwapChain1) callconv(.winapi) u32,
        Release: *const fn (*IDXGISwapChain1) callconv(.winapi) u32,
        // IDXGIObject (3..6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject (7)
        GetDevice: *const anyopaque,
        // IDXGISwapChain (8..17)
        Present: *const fn (*IDXGISwapChain1, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain1, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (*IDXGISwapChain1, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
    };

    pub fn release(self: *IDXGISwapChain1) void {
        _ = self.vtable.Release(self);
    }
};

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (*IDXGIFactory2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGIFactory2) callconv(.winapi) u32,
        Release: *const fn (*IDXGIFactory2) callconv(.winapi) u32,
        // IDXGIObject (3..6)
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory (7..11)
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const anyopaque,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
        // IDXGIFactory1 (12..13)
        EnumAdapters1: *const anyopaque,
        IsCurrent: *const anyopaque,
        // IDXGIFactory2 (14..15)
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const fn (
            *IDXGIFactory2,
            *anyopaque,
            HWND,
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*const anyopaque,
            ?*anyopaque,
            *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IDXGIFactory2) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11Device, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11Device) callconv(.winapi) u32,
        Release: *const fn (*ID3D11Device) callconv(.winapi) u32,
    };

    pub fn release(self: *ID3D11Device) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (*ID3D11DeviceContext, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        // ID3D11DeviceChild (3..6)
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        // ID3D11DeviceContext (7..48)
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const anyopaque,
        Unmap: *const anyopaque,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const anyopaque,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const anyopaque,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const fn (
            *ID3D11DeviceContext,
            *anyopaque,
            u32,
            ?*const D3D11_BOX,
            *const anyopaque,
            u32,
            u32,
        ) callconv(.winapi) void,
    };

    pub fn release(self: *ID3D11DeviceContext) void {
        _ = self.vtable.Release(self);
    }
};

const D3D11CreateDeviceFn = *const fn (
    pAdapter: ?*anyopaque,
    DriverType: u32,
    Software: ?HMODULE,
    Flags: u32,
    pFeatureLevels: ?[*]const u32,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*u32,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, hFile: ?*anyopaque, flags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: DWORD) callconv(.winapi) DWORD;

const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;

pub const DriverMode = enum {
    disabled,
    hardware,
    warp,
};

pub fn requestedMode() DriverMode {
    if (comptime builtin.os.tag != .windows) return .disabled;
    var buf: [32]u16 = undefined;
    const n = GetEnvironmentVariableW(
        std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_WIN32_PRESENTER"),
        &buf,
        buf.len,
    );
    if (n == 0 or n >= buf.len) return .disabled;
    var ascii: [32]u8 = undefined;
    for (buf[0..n], 0..) |ch, i| ascii[i] = if (ch < 0x80) @intCast(ch) else '?';
    const val = ascii[0..n];
    if (std.ascii.eqlIgnoreCase(val, "warp")) return .warp;
    if (std.ascii.eqlIgnoreCase(val, "d3d11") or std.ascii.eqlIgnoreCase(val, "dxgi")) return .hardware;
    return .disabled;
}

pub const Presenter = struct {
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swap_chain: *IDXGISwapChain1,
    width: u32,
    height: u32,
    is_warp: bool,
    staging: []u8 = &.{},

    pub fn init(hwnd: HWND, force_warp: bool) !Presenter {
        const d3d_mod = LoadLibraryExW(
            std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll"),
            null,
            LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse return error.D3D11Unavailable;
        const create_fn_ptr = GetProcAddress(d3d_mod, "D3D11CreateDevice") orelse
            return error.D3D11Unavailable;
        const createDevice: D3D11CreateDeviceFn = @ptrCast(create_fn_ptr);

        const levels = [_]u32{
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL_10_0,
        };

        var device_opt: ?*ID3D11Device = null;
        var context_opt: ?*ID3D11DeviceContext = null;
        var level: u32 = 0;
        var is_warp = force_warp;

        var hr: HRESULT = -1;
        if (!force_warp) {
            hr = createDevice(
                null,
                D3D_DRIVER_TYPE_HARDWARE,
                null,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                &levels,
                levels.len,
                D3D11_SDK_VERSION,
                &device_opt,
                &level,
                &context_opt,
            );
        }
        if (hr < 0 or device_opt == null) {
            is_warp = true;
            hr = createDevice(
                null,
                D3D_DRIVER_TYPE_WARP,
                null,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                &levels,
                levels.len,
                D3D11_SDK_VERSION,
                &device_opt,
                &level,
                &context_opt,
            );
            if (hr < 0) return error.D3D11CreateDeviceFailed;
        }

        const device = device_opt orelse return error.D3D11CreateDeviceFailed;
        errdefer device.release();
        const context = context_opt orelse return error.D3D11CreateDeviceFailed;
        errdefer context.release();

        var dxgi_dev_raw: ?*anyopaque = null;
        if (device.vtable.QueryInterface(device, &IID_IDXGIDevice, &dxgi_dev_raw) < 0) {
            return error.DxgiQueryFailed;
        }
        const dxgi_dev: *IDXGIDevice = @ptrCast(@alignCast(dxgi_dev_raw.?));
        defer dxgi_dev.release();

        var adapter_opt: ?*IDXGIAdapter = null;
        if (dxgi_dev.vtable.GetAdapter(dxgi_dev, &adapter_opt) < 0) return error.DxgiQueryFailed;
        const adapter = adapter_opt orelse return error.DxgiQueryFailed;
        defer adapter.release();

        var factory_raw: ?*anyopaque = null;
        if (adapter.vtable.GetParent(adapter, &IID_IDXGIFactory2, &factory_raw) < 0) {
            return error.DxgiQueryFailed;
        }
        const factory: *IDXGIFactory2 = @ptrCast(@alignCast(factory_raw.?));
        defer factory.release();

        const desc: DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = 64,
            .Height = 64,
            .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
            .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD,
        };
        var swap_chain_opt: ?*IDXGISwapChain1 = null;
        if (factory.vtable.CreateSwapChainForHwnd(
            factory,
            device,
            hwnd,
            &desc,
            null,
            null,
            &swap_chain_opt,
        ) < 0) return error.DxgiSwapChainFailed;
        const swap_chain = swap_chain_opt orelse return error.DxgiSwapChainFailed;

        log.info("initialized D3D11 flip-model presenter warp={} feature_level=0x{x}", .{ is_warp, level });
        return .{
            .device = device,
            .context = context,
            .swap_chain = swap_chain,
            .width = 64,
            .height = 64,
            .is_warp = is_warp,
        };
    }

    pub fn deinit(self: *Presenter) void {
        if (self.staging.len > 0) std.heap.page_allocator.free(self.staging);
        self.swap_chain.release();
        self.context.release();
        self.device.release();
        self.* = undefined;
    }

    pub fn presentFromGL(
        self: *Presenter,
        width: u32,
        height: u32,
        vsync: bool,
        glReadPixels: *const fn (c_int, c_int, c_int, c_int, c_uint, c_uint, ?*anyopaque) callconv(.winapi) void,
    ) !void {
        if (width == 0 or height == 0) return;
        if (width != self.width or height != self.height) {
            if (self.swap_chain.vtable.ResizeBuffers(
                self.swap_chain,
                2,
                width,
                height,
                DXGI_FORMAT_B8G8R8A8_UNORM,
                0,
            ) < 0) return error.DxgiResizeFailed;
            self.width = width;
            self.height = height;
        }

        const row_pitch = width * 4;
        const needed = @as(usize, row_pitch) * height;
        if (self.staging.len < needed) {
            if (self.staging.len > 0) std.heap.page_allocator.free(self.staging);
            self.staging = try std.heap.page_allocator.alloc(u8, needed);
        }

        const GL_BGRA: c_uint = 0x80E1;
        const GL_UNSIGNED_BYTE: c_uint = 0x1401;
        glReadPixels(0, 0, @intCast(width), @intCast(height), GL_BGRA, GL_UNSIGNED_BYTE, self.staging.ptr);

        // Flip vertically in-place so OpenGL bottom-up matches DXGI top-down.
        var y: u32 = 0;
        const half = height / 2;
        while (y < half) : (y += 1) {
            const top_row = self.staging[y * row_pitch ..][0..row_pitch];
            const bot_row = self.staging[(height - 1 - y) * row_pitch ..][0..row_pitch];
            for (top_row, bot_row) |*a, *b| std.mem.swap(u8, a, b);
        }

        var back_buffer_raw: ?*anyopaque = null;
        if (self.swap_chain.vtable.GetBuffer(
            self.swap_chain,
            0,
            &IID_ID3D11Texture2D,
            &back_buffer_raw,
        ) < 0) return error.DxgiBackBufferFailed;
        const back_buffer: *IUnknown = @ptrCast(@alignCast(back_buffer_raw.?));
        defer back_buffer.release();

        const box: D3D11_BOX = .{
            .left = 0,
            .top = 0,
            .right = width,
            .bottom = height,
        };
        self.context.vtable.UpdateSubresource(
            self.context,
            back_buffer,
            0,
            &box,
            self.staging.ptr,
            row_pitch,
            0,
        );

        _ = self.swap_chain.vtable.Present(self.swap_chain, if (vsync) 1 else 0, 0);
    }
};

test "d3d11 presenter struct layout" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try testing.expectEqual(@as(usize, 48), @sizeOf(DXGI_SWAP_CHAIN_DESC1));
}
