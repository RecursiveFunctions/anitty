const internal_os = @import("../os/main.zig");

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const c = @import("win32/c.zig");
pub const clipboard = @import("win32/clipboard.zig");
pub const ime = @import("win32/ime.zig");
pub const ipc = @import("win32/ipc.zig");
pub const key = @import("win32/key.zig");
pub const hotkeys = @import("win32/hotkeys.zig");
pub const SearchOverlay = @import("win32/SearchOverlay.zig");
pub const SurfaceOverlay = @import("win32/SurfaceOverlay.zig");
pub const CommandPalette = @import("win32/CommandPalette.zig");
pub const TabOverview = @import("win32/TabOverview.zig");
pub const QuickTerminal = @import("win32/QuickTerminal.zig");
pub const InspectorWindow = @import("win32/InspectorWindow.zig");
pub const SplitView = @import("win32/SplitView.zig");
pub const UndoHistory = @import("win32/UndoHistory.zig");
pub const updater = @import("win32/updater.zig");
pub const toast = @import("win32/toast.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
