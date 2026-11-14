//! Minimal pure-Zig `.po` to `.mo` compiler used when building Ghostty
//! localization catalogs on platforms (such as Windows) where GNU `msgfmt`
//! may not be installed.
//!
//! Usage:
//!   po2mo <input.po> <output.mo>

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3) {
        std.log.err("usage: po2mo <input.po> <output.mo>", .{});
        std.process.exit(1);
    }

    const po_bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        alloc,
        .unlimited,
    );

    const mo_bytes = try compilePoToMo(alloc, po_bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = mo_bytes,
    });
}

pub const Pair = struct {
    id: []const u8,
    str: []const u8,
};

pub fn compilePoToMo(alloc: Allocator, po_source: []const u8) ![]u8 {
    var pairs: std.ArrayList(Pair) = .empty;
    defer {
        for (pairs.items) |p| {
            alloc.free(p.id);
            alloc.free(p.str);
        }
        pairs.deinit(alloc);
    }

    const State = enum { idle, in_msgctxt, in_msgid, in_msgid_plural, in_msgstr, in_msgstr_ignore };
    var state: State = .idle;
    var fuzzy = false;

    var ctxt_buf: std.ArrayList(u8) = .empty;
    defer ctxt_buf.deinit(alloc);
    var has_ctxt = false;

    var id_buf: std.ArrayList(u8) = .empty;
    defer id_buf.deinit(alloc);

    var str_buf: std.ArrayList(u8) = .empty;
    defer str_buf.deinit(alloc);

    const flushEntry = struct {
        fn call(
            a: Allocator,
            list: *std.ArrayList(Pair),
            st: *State,
            fz: *bool,
            hc: *bool,
            cb: *std.ArrayList(u8),
            ib: *std.ArrayList(u8),
            sb: *std.ArrayList(u8),
        ) !void {
            defer {
                st.* = .idle;
                fz.* = false;
                hc.* = false;
                cb.clearRetainingCapacity();
                ib.clearRetainingCapacity();
                sb.clearRetainingCapacity();
            }
            if (st.* == .idle or fz.*) return;
            if (ib.items.len == 0 or sb.items.len == 0) return;

            const id_owned = if (hc.*) blk: {
                const full = try a.alloc(u8, cb.items.len + 1 + ib.items.len);
                @memcpy(full[0..cb.items.len], cb.items);
                full[cb.items.len] = 0x04;
                @memcpy(full[cb.items.len + 1 ..], ib.items);
                break :blk full;
            } else try a.dupe(u8, ib.items);

            const str_owned = try a.dupe(u8, sb.items);
            try list.append(a, .{ .id = id_owned, .str = str_owned });
        }
    }.call;

    var it = std.mem.splitScalar(u8, po_source, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) {
            try flushEntry(alloc, &pairs, &state, &fuzzy, &has_ctxt, &ctxt_buf, &id_buf, &str_buf);
            continue;
        }
        if (line[0] == '#') {
            if (state == .in_msgstr or state == .in_msgstr_ignore) {
                try flushEntry(alloc, &pairs, &state, &fuzzy, &has_ctxt, &ctxt_buf, &id_buf, &str_buf);
            }
            if (std.mem.startsWith(u8, line, "#,") and std.mem.indexOf(u8, line, "fuzzy") != null) {
                fuzzy = true;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "msgctxt ")) {
            if (state == .in_msgstr or state == .in_msgstr_ignore) {
                try flushEntry(alloc, &pairs, &state, &fuzzy, &has_ctxt, &ctxt_buf, &id_buf, &str_buf);
            }
            state = .in_msgctxt;
            has_ctxt = true;
            ctxt_buf.clearRetainingCapacity();
            try appendQuoted(alloc, &ctxt_buf, line["msgctxt ".len..]);
        } else if (std.mem.startsWith(u8, line, "msgid_plural ")) {
            state = .in_msgid_plural;
        } else if (std.mem.startsWith(u8, line, "msgid ")) {
            if (state == .in_msgstr or state == .in_msgstr_ignore) {
                try flushEntry(alloc, &pairs, &state, &fuzzy, &has_ctxt, &ctxt_buf, &id_buf, &str_buf);
            }
            state = .in_msgid;
            id_buf.clearRetainingCapacity();
            try appendQuoted(alloc, &id_buf, line["msgid ".len..]);
        } else if (std.mem.startsWith(u8, line, "msgstr[0] ")) {
            state = .in_msgstr;
            str_buf.clearRetainingCapacity();
            try appendQuoted(alloc, &str_buf, line["msgstr[0] ".len..]);
        } else if (std.mem.startsWith(u8, line, "msgstr[")) {
            state = .in_msgstr_ignore;
        } else if (std.mem.startsWith(u8, line, "msgstr ")) {
            state = .in_msgstr;
            str_buf.clearRetainingCapacity();
            try appendQuoted(alloc, &str_buf, line["msgstr ".len..]);
        } else if (line[0] == '"') {
            switch (state) {
                .in_msgctxt => try appendQuoted(alloc, &ctxt_buf, line),
                .in_msgid => try appendQuoted(alloc, &id_buf, line),
                .in_msgstr => try appendQuoted(alloc, &str_buf, line),
                .idle, .in_msgid_plural, .in_msgstr_ignore => {},
            }
        }
    }
    try flushEntry(alloc, &pairs, &state, &fuzzy, &has_ctxt, &ctxt_buf, &id_buf, &str_buf);

    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    // Deduplicate sorted keys if any exist
    var unique_len: usize = 0;
    for (pairs.items) |p| {
        if (unique_len > 0 and std.mem.eql(u8, pairs.items[unique_len - 1].id, p.id)) {
            alloc.free(pairs.items[unique_len - 1].id);
            alloc.free(pairs.items[unique_len - 1].str);
            pairs.items[unique_len - 1] = p;
        } else {
            pairs.items[unique_len] = p;
            unique_len += 1;
        }
    }
    pairs.items.len = unique_len;
    const items = pairs.items;

    const n: u32 = @intCast(items.len);
    const header_size: u32 = 28;
    const orig_table_offset: u32 = header_size;
    const trans_table_offset: u32 = orig_table_offset + n * 8;
    var pool_offset: u32 = trans_table_offset + n * 8;

    var total_size: usize = pool_offset;
    for (items) |item| {
        total_size += item.id.len + 1 + item.str.len + 1;
    }

    const out = try alloc.alloc(u8, total_size);
    @memset(out, 0);

    std.mem.writeInt(u32, out[0..4], 0x950412de, .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], n, .little);
    std.mem.writeInt(u32, out[12..16], orig_table_offset, .little);
    std.mem.writeInt(u32, out[16..20], trans_table_offset, .little);
    std.mem.writeInt(u32, out[20..24], 0, .little);
    std.mem.writeInt(u32, out[24..28], trans_table_offset + n * 8, .little);

    for (items, 0..) |item, i| {
        const entry_off: usize = orig_table_offset + @as(usize, @intCast(i)) * 8;
        const len: u32 = @intCast(item.id.len);
        std.mem.writeInt(u32, out[entry_off..][0..4], len, .little);
        std.mem.writeInt(u32, out[entry_off + 4 ..][0..4], pool_offset, .little);
        @memcpy(out[pool_offset .. pool_offset + item.id.len], item.id);
        out[pool_offset + item.id.len] = 0;
        pool_offset += len + 1;
    }

    for (items, 0..) |item, i| {
        const entry_off: usize = trans_table_offset + @as(usize, @intCast(i)) * 8;
        const len: u32 = @intCast(item.str.len);
        std.mem.writeInt(u32, out[entry_off..][0..4], len, .little);
        std.mem.writeInt(u32, out[entry_off + 4 ..][0..4], pool_offset, .little);
        @memcpy(out[pool_offset .. pool_offset + item.str.len], item.str);
        out[pool_offset + item.str.len] = 0;
        pool_offset += len + 1;
    }

    return out;
}

fn appendQuoted(alloc: Allocator, dst: *std.ArrayList(u8), raw: []const u8) !void {
    const s = std.mem.trim(u8, raw, " \t\r");
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return;
    const inner = s[1 .. s.len - 1];
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            switch (inner[i]) {
                'n' => try dst.append(alloc, '\n'),
                'r' => try dst.append(alloc, '\r'),
                't' => try dst.append(alloc, '\t'),
                '"' => try dst.append(alloc, '"'),
                '\\' => try dst.append(alloc, '\\'),
                else => try dst.append(alloc, inner[i]),
            }
        } else {
            try dst.append(alloc, inner[i]);
        }
    }
}
