const luau = @import("luau");

const VM = luau.VM;

pub const filesystem = struct {
    pub const File = @import("filesystem/File.zig");
};

pub const network = struct {
    pub const Socket = @import("network/Socket.zig");
};

fn loadNamespace(comptime ns: type, L: *VM.lua.State) void {
    inline for (@typeInfo(ns).@"struct".decls) |field| {
        const object = @field(ns, field.name);
        if (comptime !object.PlatformSupported())
            continue;
        if (@hasDecl(object, "load")) {
            object.load(L);
        }
    }
}

pub fn load(L: *VM.lua.State) void {
    inline for (@typeInfo(@This()).@"struct".decls) |field| {
        const ns = @field(@This(), field.name);
        switch (@typeInfo(@TypeOf(ns))) {
            .type => loadNamespace(ns, L),
            else => continue,
        }
    }
}
