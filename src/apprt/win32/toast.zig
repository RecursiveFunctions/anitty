const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");

const log = std.log.scoped(.win32_toast);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const aumid = L(@import("../../build_config.zig").bundle_id);

const HSTRING = *opaque {};

const HSTRING_HEADER = extern struct {
    reserved: if (@sizeOf(usize) == 8) [3]usize else [5]usize = @splat(0),
};

const FastHString = struct {
    header: HSTRING_HEADER = .{},
    hstr: ?HSTRING = null,

    fn bind(self: *FastHString, apis: *const CombaseApis, wide: [:0]const u16) ?HSTRING {
        self.* = .{};
        const hr = apis.WindowsCreateStringReference(
            wide.ptr,
            @intCast(wide.len),
            &self.header,
            &self.hstr,
        );
        if (hr < 0) return null;
        return self.hstr;
    }
};

const WindowsCreateStringReferenceFn = *const fn (
    sourceString: c.LPCWSTR,
    length: u32,
    hstringHeader: *HSTRING_HEADER,
    string: *?HSTRING,
) callconv(.winapi) c.HRESULT;

const RoActivateInstanceFn = *const fn (
    activatableClassId: ?HSTRING,
    instance: *?*IInspectable,
) callconv(.winapi) c.HRESULT;

const RoGetActivationFactoryFn = *const fn (
    activatableClassId: ?HSTRING,
    iid: *const c.GUID,
    factory: *?*anyopaque,
) callconv(.winapi) c.HRESULT;

const CombaseApis = struct {
    WindowsCreateStringReference: WindowsCreateStringReferenceFn,
    RoActivateInstance: RoActivateInstanceFn,
    RoGetActivationFactory: RoGetActivationFactoryFn,
};

var combase_apis: ?CombaseApis = null;
var combase_loaded: bool = false;

fn getCombaseApis() ?CombaseApis {
    if (combase_loaded) return combase_apis;
    combase_loaded = true;
    const mod = c.LoadLibraryExW(L("combase.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
    const wcsr = c.GetProcAddress(mod, "WindowsCreateStringReference") orelse return null;
    const rai = c.GetProcAddress(mod, "RoActivateInstance") orelse return null;
    const rgaf = c.GetProcAddress(mod, "RoGetActivationFactory") orelse return null;
    combase_apis = .{
        .WindowsCreateStringReference = @ptrCast(wcsr),
        .RoActivateInstance = @ptrCast(rai),
        .RoGetActivationFactory = @ptrCast(rgaf),
    };
    return combase_apis;
}

const IID_IXmlDocument: c.GUID = .{
    .Data1 = 0xF7F3A506,
    .Data2 = 0x1E87,
    .Data3 = 0x42D6,
    .Data4 = .{ 0xBC, 0xFB, 0xB8, 0xC8, 0x09, 0xFA, 0x54, 0x94 },
};

const IID_IXmlDocumentIO: c.GUID = .{
    .Data1 = 0x6CD0E74E,
    .Data2 = 0xEE65,
    .Data3 = 0x4489,
    .Data4 = .{ 0x9E, 0xBF, 0xCA, 0x43, 0xE8, 0x7B, 0xA6, 0x37 },
};

const IID_IToastNotificationManagerStatics: c.GUID = .{
    .Data1 = 0x50AC103F,
    .Data2 = 0xD235,
    .Data3 = 0x4598,
    .Data4 = .{ 0xBB, 0xEF, 0x98, 0xFE, 0x4D, 0x1A, 0x3A, 0xD4 },
};

const IID_IToastNotificationFactory: c.GUID = .{
    .Data1 = 0x04124B20,
    .Data2 = 0x82C6,
    .Data3 = 0x4229,
    .Data4 = .{ 0xB1, 0x09, 0xFD, 0x9E, 0xD4, 0x66, 0x2B, 0x53 },
};

const IInspectable = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IInspectable, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IInspectable) callconv(.winapi) u32,
        Release: *const fn (*IInspectable) callconv(.winapi) u32,
        GetIids: *const anyopaque,
        GetRuntimeClassName: *const anyopaque,
        GetTrustLevel: *const anyopaque,
    };
};

const IXmlDocument = extern struct {
    vtable: *const IInspectable.VTable,
};

const IXmlDocumentIO = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IXmlDocumentIO, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IXmlDocumentIO) callconv(.winapi) u32,
        Release: *const fn (*IXmlDocumentIO) callconv(.winapi) u32,
        GetIids: *const anyopaque,
        GetRuntimeClassName: *const anyopaque,
        GetTrustLevel: *const anyopaque,
        LoadXml: *const fn (*IXmlDocumentIO, ?HSTRING) callconv(.winapi) c.HRESULT,
    };
};

const IToastNotification = extern struct {
    vtable: *const IInspectable.VTable,
};

const IToastNotifier = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IToastNotifier, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IToastNotifier) callconv(.winapi) u32,
        Release: *const fn (*IToastNotifier) callconv(.winapi) u32,
        GetIids: *const anyopaque,
        GetRuntimeClassName: *const anyopaque,
        GetTrustLevel: *const anyopaque,
        Show: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) c.HRESULT,
    };
};

const IToastNotificationManagerStatics = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IToastNotificationManagerStatics, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IToastNotificationManagerStatics) callconv(.winapi) u32,
        Release: *const fn (*IToastNotificationManagerStatics) callconv(.winapi) u32,
        GetIids: *const anyopaque,
        GetRuntimeClassName: *const anyopaque,
        GetTrustLevel: *const anyopaque,
        CreateToastNotifier: *const fn (*IToastNotificationManagerStatics, *?*IToastNotifier) callconv(.winapi) c.HRESULT,
        CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, ?HSTRING, *?*IToastNotifier) callconv(.winapi) c.HRESULT,
    };
};

const IToastNotificationFactory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IToastNotificationFactory, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        AddRef: *const fn (*IToastNotificationFactory) callconv(.winapi) u32,
        Release: *const fn (*IToastNotificationFactory) callconv(.winapi) u32,
        GetIids: *const anyopaque,
        GetRuntimeClassName: *const anyopaque,
        GetTrustLevel: *const anyopaque,
        CreateToastNotification: *const fn (*IToastNotificationFactory, *IXmlDocument, *?*IToastNotification) callconv(.winapi) c.HRESULT,
    };
};

pub fn show(alloc: Allocator, title: []const u8, body: []const u8) bool {
    const apis = getCombaseApis() orelse return false;

    const xml_utf8 = buildToastXml(alloc, title, body) catch return false;
    defer alloc.free(xml_utf8);

    const xml_wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, xml_utf8) catch return false;
    defer alloc.free(xml_wide);

    var xml_class: FastHString = .{};
    const xml_class_hstr = xml_class.bind(&apis, L("Windows.Data.Xml.Dom.XmlDocument")) orelse return false;
    var doc_inspectable: ?*IInspectable = null;
    if (apis.RoActivateInstance(xml_class_hstr, &doc_inspectable) < 0 or doc_inspectable == null) return false;
    const doc_insp = doc_inspectable.?;
    defer _ = doc_insp.vtable.Release(doc_insp);

    var doc_io_raw: ?*anyopaque = null;
    if (doc_insp.vtable.QueryInterface(doc_insp, &IID_IXmlDocumentIO, &doc_io_raw) < 0 or doc_io_raw == null) return false;
    const doc_io: *IXmlDocumentIO = @ptrCast(@alignCast(doc_io_raw.?));
    defer _ = doc_io.vtable.Release(doc_io);

    var xml_fast: FastHString = .{};
    const xml_hstr = xml_fast.bind(&apis, xml_wide) orelse return false;
    if (doc_io.vtable.LoadXml(doc_io, xml_hstr) < 0) return false;

    var doc_raw: ?*anyopaque = null;
    if (doc_insp.vtable.QueryInterface(doc_insp, &IID_IXmlDocument, &doc_raw) < 0 or doc_raw == null) return false;
    const xml_doc: *IXmlDocument = @ptrCast(@alignCast(doc_raw.?));
    defer _ = xml_doc.vtable.Release(@ptrCast(xml_doc));

    var mgr_class: FastHString = .{};
    const mgr_class_hstr = mgr_class.bind(&apis, L("Windows.UI.Notifications.ToastNotificationManager")) orelse return false;
    var mgr_raw: ?*anyopaque = null;
    if (apis.RoGetActivationFactory(mgr_class_hstr, &IID_IToastNotificationManagerStatics, &mgr_raw) < 0 or mgr_raw == null) return false;
    const mgr: *IToastNotificationManagerStatics = @ptrCast(@alignCast(mgr_raw.?));
    defer _ = mgr.vtable.Release(mgr);

    var aumid_fast: FastHString = .{};
    const aumid_hstr = aumid_fast.bind(&apis, aumid) orelse return false;
    var notifier: ?*IToastNotifier = null;
    if (mgr.vtable.CreateToastNotifierWithId(mgr, aumid_hstr, &notifier) < 0 or notifier == null) return false;
    const notif_sender = notifier.?;
    defer _ = notif_sender.vtable.Release(notif_sender);

    var toast_class: FastHString = .{};
    const toast_class_hstr = toast_class.bind(&apis, L("Windows.UI.Notifications.ToastNotification")) orelse return false;
    var factory_raw: ?*anyopaque = null;
    if (apis.RoGetActivationFactory(toast_class_hstr, &IID_IToastNotificationFactory, &factory_raw) < 0 or factory_raw == null) return false;
    const factory: *IToastNotificationFactory = @ptrCast(@alignCast(factory_raw.?));
    defer _ = factory.vtable.Release(factory);

    var toast: ?*IToastNotification = null;
    if (factory.vtable.CreateToastNotification(factory, xml_doc, &toast) < 0 or toast == null) return false;
    const toast_obj = toast.?;
    defer _ = toast_obj.vtable.Release(@ptrCast(toast_obj));

    const hr = notif_sender.vtable.Show(notif_sender, toast_obj);
    if (hr < 0) {
        log.debug("WinRT IToastNotifier.Show failed hr=0x{x}, falling back to balloon", .{@as(u32, @bitCast(hr))});
        return false;
    }
    log.debug("WinRT toast notification shown title={s}", .{title});
    return true;
}

pub fn buildToastXml(alloc: Allocator, title: []const u8, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("<toast><visual><binding template=\"ToastGeneric\"><text>");
    try writeXmlEscaped(w, if (title.len > 0) title else "Anitty");
    try w.writeAll("</text>");
    if (body.len > 0) {
        try w.writeAll("<text>");
        try writeXmlEscaped(w, body);
        try w.writeAll("</text>");
    }
    try w.writeAll("</binding></visual></toast>");
    return try out.toOwnedSlice();
}

fn writeXmlEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            0x09, 0x0A, 0x0D => try w.writeByte(ch),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {},
            else => try w.writeByte(ch),
        }
    }
}

test "toast: buildToastXml escapes XML entities" {
    const testing = std.testing;
    const xml = try buildToastXml(testing.allocator, "Build & Test <1>", "Done \"ok\" 'yes'");
    defer testing.allocator.free(xml);
    try testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>Build &amp; Test &lt;1&gt;</text><text>Done &quot;ok&quot; &apos;yes&apos;</text></binding></visual></toast>",
        xml,
    );
}
