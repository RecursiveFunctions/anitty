const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const App = @import("App.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32_hotkeys);

pub const Registered = struct {
    id: c_int,
    trigger: input.Trigger,
};

pub const State = struct {
    entries: std.ArrayList(Registered) = .empty,

    pub fn deinit(self: *State, alloc: Allocator, hwnd: ?c.HWND) void {
        self.unregisterAll(hwnd);
        self.entries.deinit(alloc);
        self.entries = .empty;
    }

    pub fn unregisterAll(self: *State, hwnd: ?c.HWND) void {
        if (hwnd) |h| {
            for (self.entries.items) |reg| {
                _ = c.UnregisterHotKey(h, reg.id);
            }
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn sync(self: *State, app: *App) void {
        const hwnd = app.msg_hwnd orelse return;
        const alloc = app.core_app.alloc;
        self.unregisterAll(hwnd);

        const hkl = c.GetKeyboardLayout(0);
        var next_id: c_int = 1;
        var it = app.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            const is_global = switch (entry.value_ptr.*) {
                .leader => false,
                inline .leaf, .leaf_chained => |leaf| leaf.generic().flags.global,
            };
            if (!is_global) continue;

            const trigger = entry.key_ptr.*;
            const vk = vkFromTrigger(trigger, hkl) orelse {
                log.warn("unable to map global hotkey trigger={f}", .{trigger});
                continue;
            };
            const mods = modifiersFromMods(trigger.mods) | c.MOD_NOREPEAT;
            const id = next_id;
            next_id += 1;

            if (!c.RegisterHotKey(hwnd, id, mods, vk).toBool()) {
                log.warn("RegisterHotKey failed trigger={f} vk=0x{x}", .{ trigger, vk });
                continue;
            }
            self.entries.append(alloc, .{ .id = id, .trigger = trigger }) catch {
                _ = c.UnregisterHotKey(hwnd, id);
                break;
            };
            log.debug("registered global hotkey id={d} trigger={f} vk=0x{x}", .{ id, trigger, vk });
        }
    }

    pub fn handle(self: *const State, app: *App, id: c_int) bool {
        for (self.entries.items) |reg| {
            if (reg.id != id) continue;
            const event: input.KeyEvent = switch (reg.trigger.key) {
                .physical => |k| .{
                    .action = .press,
                    .key = k,
                    .mods = reg.trigger.mods,
                },
                .unicode => |cp| .{
                    .action = .press,
                    .key = .unidentified,
                    .mods = reg.trigger.mods,
                    .unshifted_codepoint = cp,
                },
                .catch_all => return false,
            };
            return app.core_app.keyEvent(app, event);
        }
        return false;
    }
};

pub fn modifiersFromMods(mods: input.Mods) c.UINT {
    var out: c.UINT = 0;
    if (mods.alt) out |= c.MOD_ALT;
    if (mods.ctrl) out |= c.MOD_CONTROL;
    if (mods.shift) out |= c.MOD_SHIFT;
    if (mods.super) out |= c.MOD_WIN;
    return out;
}

pub fn vkFromTrigger(trigger: input.Trigger, hkl: ?c.HKL) ?c.UINT {
    return switch (trigger.key) {
        .physical => |k| vkFromPhysicalKey(k, hkl),
        .unicode => |cp| vkFromUnicode(cp, hkl),
        .catch_all => null,
    };
}

pub fn vkFromUnicode(cp: u21, hkl: ?c.HKL) ?c.UINT {
    if (cp >= 'a' and cp <= 'z') return @intCast(cp - 'a' + 'A');
    if (cp >= 'A' and cp <= 'Z') return @intCast(cp);
    if (cp >= '0' and cp <= '9') return @intCast(cp);
    switch (cp) {
        ' ' => return 0x20,
        '`', '~' => return 0xC0,
        '-', '_' => return 0xBD,
        '=', '+' => return 0xBB,
        '[', '{' => return 0xDB,
        ']', '}' => return 0xDD,
        '\\', '|' => return 0xDC,
        ';', ':' => return 0xBA,
        '\'', '"' => return 0xDE,
        ',', '<' => return 0xBC,
        '.', '>' => return 0xBE,
        '/', '?' => return 0xBF,
        else => {},
    }
    if (cp <= 0xFFFF and hkl != null) {
        const res = c.VkKeyScanExW(@intCast(cp), hkl);
        if (res != -1) return @intCast(@as(u16, @bitCast(res)) & 0xFF);
    }
    return null;
}

pub fn vkFromPhysicalKey(k: input.Key, hkl: ?c.HKL) ?c.UINT {
    return switch (k) {
        .key_a => 'A',
        .key_b => 'B',
        .key_c => 'C',
        .key_d => 'D',
        .key_e => 'E',
        .key_f => 'F',
        .key_g => 'G',
        .key_h => 'H',
        .key_i => 'I',
        .key_j => 'J',
        .key_k => 'K',
        .key_l => 'L',
        .key_m => 'M',
        .key_n => 'N',
        .key_o => 'O',
        .key_p => 'P',
        .key_q => 'Q',
        .key_r => 'R',
        .key_s => 'S',
        .key_t => 'T',
        .key_u => 'U',
        .key_v => 'V',
        .key_w => 'W',
        .key_x => 'X',
        .key_y => 'Y',
        .key_z => 'Z',
        .digit_0 => '0',
        .digit_1 => '1',
        .digit_2 => '2',
        .digit_3 => '3',
        .digit_4 => '4',
        .digit_5 => '5',
        .digit_6 => '6',
        .digit_7 => '7',
        .digit_8 => '8',
        .digit_9 => '9',
        .f1 => 0x70,
        .f2 => 0x71,
        .f3 => 0x72,
        .f4 => 0x73,
        .f5 => 0x74,
        .f6 => 0x75,
        .f7 => 0x76,
        .f8 => 0x77,
        .f9 => 0x78,
        .f10 => 0x79,
        .f11 => 0x7A,
        .f12 => 0x7B,
        .f13 => 0x7C,
        .f14 => 0x7D,
        .f15 => 0x7E,
        .f16 => 0x7F,
        .f17 => 0x80,
        .f18 => 0x81,
        .f19 => 0x82,
        .f20 => 0x83,
        .f21 => 0x84,
        .f22 => 0x85,
        .f23 => 0x86,
        .f24 => 0x87,
        .enter, .numpad_enter => 0x0D,
        .escape => 0x1B,
        .backspace => 0x08,
        .tab => 0x09,
        .space => 0x20,
        .backquote => 0xC0,
        .minus => 0xBD,
        .equal => 0xBB,
        .bracket_left => 0xDB,
        .bracket_right => 0xDD,
        .backslash => 0xDC,
        .semicolon => 0xBA,
        .quote => 0xDE,
        .comma => 0xBC,
        .period => 0xBE,
        .slash => 0xBF,
        .arrow_left => 0x25,
        .arrow_up => 0x26,
        .arrow_right => 0x27,
        .arrow_down => 0x28,
        .page_up => 0x21,
        .page_down => 0x22,
        .end => 0x23,
        .home => 0x24,
        .insert => 0x2D,
        .delete => 0x2E,
        else => sc: {
            if (hkl != null) {
                for (input.keycodes.entries) |entry| {
                    if (entry.key == k and entry.native != 0) {
                        const vk = c.MapVirtualKeyExW(entry.native, c.MAPVK_VSC_TO_VK_EX, hkl);
                        if (vk != 0) break :sc vk;
                    }
                }
            }
            break :sc null;
        },
    };
}

test "hotkeys modifiersFromMods and vkFromTrigger" {
    const testing = std.testing;
    const mods = modifiersFromMods(.{ .ctrl = true, .shift = true, .alt = true });
    try testing.expectEqual(c.MOD_CONTROL | c.MOD_SHIFT | c.MOD_ALT, mods);
    try testing.expectEqual(@as(?c.UINT, 0xC0), vkFromTrigger(.{ .key = .{ .physical = .backquote } }, null));
    try testing.expectEqual(@as(?c.UINT, 'T'), vkFromTrigger(.{ .key = .{ .unicode = 't' } }, null));
    try testing.expectEqual(@as(?c.UINT, 0x7B), vkFromTrigger(.{ .key = .{ .physical = .f12 } }, null));
}
