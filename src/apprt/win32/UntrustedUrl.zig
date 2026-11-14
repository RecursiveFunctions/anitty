const std = @import("std");
const apprt = @import("../../apprt.zig");

pub const Decision = enum {
    allow,
    confirm,
    deny,
    allow_file,
};

pub fn decide(value: apprt.action.OpenUrl) Decision {
    return switch (value.kind) {
        .text, .html => .allow,
        .unknown, .osc8 => decideUntrusted(value.url),
    };
}

fn decideUntrusted(raw: []const u8) Decision {
    if (raw.len == 0) return .deny;

    for (raw) |b| {
        if (b <= 0x20 or b == 0x7F or b == '\\') return .deny;
    }

    var utf8 = std.unicode.Utf8View.init(raw) catch return .deny;
    var it = utf8.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isUnsafeCodepoint(cp)) return .deny;
    }

    const uri = std.Uri.parse(raw) catch return .deny;
    if (uri.scheme.len <= 1) return .deny;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        std.ascii.eqlIgnoreCase(uri.scheme, "https"))
    {
        const host = uri.host orelse return .deny;
        if (host.isEmpty()) return .deny;
        return .allow;
    }

    if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto")) {
        if (uri.path.isEmpty()) return .deny;
        return .allow;
    }

    if (std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
        return .allow_file;
    }

    return .confirm;
}

fn isUnsafeCodepoint(cp: u21) bool {
    return switch (cp) {
        0x0080...0x009F,
        0x061C,
        0x200B...0x200F,
        0x2028...0x202E,
        0x2060,
        0x2066...0x2069,
        0xFEFF,
        => true,
        else => false,
    };
}

test "UntrustedUrl: trusted exports are allowed" {
    const testing = std.testing;
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .text, .url = "C:\\Temp\\out.txt" }));
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .html, .url = "C:\\Temp\\out.html" }));
}

test "UntrustedUrl: http, https, and mailto" {
    const testing = std.testing;
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .unknown, .url = "https://ghostty.org/docs" }));
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .osc8, .url = "http://example.com:8080/path?q=1#frag" }));
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .osc8, .url = "HTTPS://EXAMPLE.COM" }));
    try testing.expectEqual(Decision.allow, decide(.{ .kind = .osc8, .url = "mailto:dev@example.com" }));

    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "https:///no-host" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "http://" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "mailto:" }));
}

test "UntrustedUrl: blocks raw paths, drive letters, and UNC paths" {
    const testing = std.testing;
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "C:\\Windows\\System32\\calc.exe" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "C:/Windows/System32/calc.exe" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "\\\\server\\share\\payload.exe" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "//server/share/payload.exe" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "../run.cmd" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .unknown, .url = "src/main.zig" }));
}

test "UntrustedUrl: blocks control characters, spaces, and BiDi formatting" {
    const testing = std.testing;
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "https://example.com/a b" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "https://example.com/\x1b" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "https://example.com/\u{202E}exe.txt" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "https://example.com/\u{200B}path" }));
    try testing.expectEqual(Decision.deny, decide(.{ .kind = .osc8, .url = "https://example.com\\bad" }));
}

test "UntrustedUrl: file URLs and custom schemes" {
    const testing = std.testing;
    try testing.expectEqual(Decision.allow_file, decide(.{ .kind = .osc8, .url = "file:///C:/Users/user/notes.txt" }));
    try testing.expectEqual(Decision.allow_file, decide(.{ .kind = .unknown, .url = "file://localhost/C:/Users/user" }));

    try testing.expectEqual(Decision.confirm, decide(.{ .kind = .osc8, .url = "vscode://file/C:/src/main.zig:10" }));
    try testing.expectEqual(Decision.confirm, decide(.{ .kind = .unknown, .url = "obsidian://open?vault=notes" }));
}
