const std = @import("std");
const Allocator = std.mem.Allocator;

const header_fmt =
    "Version:0.9\r\n" ++
    "StartHTML:{d:0>10}\r\n" ++
    "EndHTML:{d:0>10}\r\n" ++
    "StartFragment:{d:0>10}\r\n" ++
    "EndFragment:{d:0>10}\r\n";

const header_len: usize = 105;
const prefix = "<html>\r\n<body>\r\n<!--StartFragment-->";
const suffix = "<!--EndFragment-->\r\n</body>\r\n</html>";

pub fn encode(alloc: Allocator, fragment: []const u8) Allocator.Error![:0]u8 {
    const start_html: usize = header_len;
    const start_fragment: usize = start_html + prefix.len;
    const end_fragment: usize = start_fragment + fragment.len;
    const end_html: usize = end_fragment + suffix.len;

    const out = try alloc.allocSentinel(u8, end_html, 0);
    errdefer alloc.free(out);

    const written = std.fmt.bufPrint(out[0..header_len], header_fmt, .{
        start_html,
        end_html,
        start_fragment,
        end_fragment,
    }) catch unreachable;
    std.debug.assert(written.len == header_len);

    @memcpy(out[start_html..start_fragment], prefix);
    @memcpy(out[start_fragment..end_fragment], fragment);
    @memcpy(out[end_fragment..end_html], suffix);

    return out;
}

test "cf_html encode offsets and slices" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const fragment = "<pre><span style=\"color:#ff0000\">hello 日本</span></pre>";
    const encoded = try encode(alloc, fragment);
    defer alloc.free(encoded);

    try testing.expect(std.mem.startsWith(u8, encoded, "Version:0.9\r\nStartHTML:0000000105\r\n"));
    try testing.expectEqual(@as(usize, 0), encoded[encoded.len]);

    const start_html: usize = 105;
    const start_fragment: usize = 141;
    const end_fragment: usize = start_fragment + fragment.len;
    const end_html: usize = encoded.len;

    try testing.expectEqualStrings(fragment, encoded[start_fragment..end_fragment]);
    try testing.expect(std.mem.startsWith(u8, encoded[start_html..end_html], "<html>\r\n<body>\r\n<!--StartFragment-->"));
    try testing.expect(std.mem.endsWith(u8, encoded[start_html..end_html], "<!--EndFragment-->\r\n</body>\r\n</html>"));
}
