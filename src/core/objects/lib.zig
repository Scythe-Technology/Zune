const luau = @import("luau");

const Luau = luau.Luau;

pub const filesystem = struct {
    pub const File = @import("filesystem/File.zig");
};

pub fn load(L: *Luau) void {
    filesystem.File.load(L);
}
