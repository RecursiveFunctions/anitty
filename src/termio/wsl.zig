const std = @import("std");
const EnvMap = std.process.Environ.Map;

pub const ExportVar = struct {
    name: []const u8,
    flags: []const u8,
};

pub const default_exports = [_]ExportVar{
    .{ .name = "TERM_PROGRAM", .flags = "u" },
    .{ .name = "TERM_PROGRAM_VERSION", .flags = "u" },
    .{ .name = "GHOSTTY_RESOURCES_DIR", .flags = "up" },
    .{ .name = "GHOSTTY_SHELL_FEATURES", .flags = "u" },
};

pub fn setup(env: *EnvMap) !void {
    const alloc = env.allocator;
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);

    if (env.get("WSLENV")) |existing| {
        try current.appendSlice(alloc, existing);
    }

    var modified = false;
    for (default_exports) |entry| {
        if (env.get(entry.name) == null) continue;
        if (containsVar(current.items, entry.name)) continue;

        if (current.items.len > 0 and current.items[current.items.len - 1] != ':') {
            try current.append(alloc, ':');
        }
        try current.appendSlice(alloc, entry.name);
        try current.append(alloc, '/');
        try current.appendSlice(alloc, entry.flags);
        modified = true;
    }

    if (modified) {
        try env.put("WSLENV", current.items);
    }
}

fn containsVar(wslenv: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, wslenv, ':');
    while (it.next()) |token| {
        const slash = std.mem.indexOfScalar(u8, token, '/') orelse token.len;
        const token_name = token[0..slash];
        if (std.ascii.eqlIgnoreCase(token_name, name)) return true;
    }
    return false;
}

test "wsl: exports present Ghostty vars to empty WSLENV" {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("TERM_PROGRAM_VERSION", "1.4.1");
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\Ghostty\\share\\ghostty");
    try env.put("GHOSTTY_SHELL_FEATURES", "cursor,title");

    try setup(&env);
    try testing.expectEqualStrings(
        "TERM_PROGRAM/u:TERM_PROGRAM_VERSION/u:GHOSTTY_RESOURCES_DIR/up:GHOSTTY_SHELL_FEATURES/u",
        env.get("WSLENV").?,
    );
}

test "wsl: skips missing vars and preserves existing WSLENV entries" {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("WSLENV", "WT_SESSION:GHOSTTY_RESOURCES_DIR/p:FOO/u");
    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("GHOSTTY_RESOURCES_DIR", "C:\\Ghostty\\share\\ghostty");

    try setup(&env);
    try testing.expectEqualStrings(
        "WT_SESSION:GHOSTTY_RESOURCES_DIR/p:FOO/u:TERM_PROGRAM/u",
        env.get("WSLENV").?,
    );
}

test "wsl: leaves WSLENV unset when no Ghostty vars exist" {
    const testing = std.testing;
    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try setup(&env);
    try testing.expect(env.get("WSLENV") == null);
}
