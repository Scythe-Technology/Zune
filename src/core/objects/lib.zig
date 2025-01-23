const luau = @import("luau");

const VM = luau.VM;

pub const filesystem = struct {
    pub const File = @import("filesystem/File.zig");
};

pub fn load(L: *VM.lua.State) void {
    filesystem.File.load(L);
}
