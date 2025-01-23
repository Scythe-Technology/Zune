const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const base64 = @import("base64.zig");

const gzip = @import("gzip.zig");
const zlib = @import("zlib.zig");
const flate = @import("flate.zig");
const lz4 = @import("lz4.zig");
const zstd = @import("zstd.zig");

const VM = luau.VM;

pub const LIB_NAME = "serde";

pub fn loadLib(L: *VM.lua.State) void {
    L.newtable();

    { // Json
        L.newtable();

        L.Zsetfieldc(-1, "encode", json.LuaEncoder(.JSON));
        L.Zsetfieldc(-1, "decode", json.LuaDecoder(.JSON));

        json.lua_setprops(L);

        L.setreadonly(-1, true);
        L.setfield(-2, "json");
    }

    { // Json5
        L.newtable();

        L.Zsetfieldc(-1, "encode", json.LuaEncoder(.JSON5));
        L.Zsetfieldc(-1, "decode", json.LuaDecoder(.JSON5));

        _ = L.getfield(-2, "json");

        _ = L.getfield(-1, "Indents");
        L.setfield(-3, "Indents");

        _ = L.getfield(-1, "Values");
        L.setfield(-3, "Values");

        L.pop(1);

        L.setreadonly(-1, true);
        L.setfield(-2, "json5");
    }

    { // Toml
        L.newtable();

        L.Zsetfieldc(-1, "encode", toml.lua_encode);
        L.Zsetfieldc(-1, "decode", toml.lua_decode);

        L.setreadonly(-1, true);
        L.setfield(-2, "toml");
    }

    { // Yaml
        L.newtable();

        L.Zsetfieldc(-1, "encode", yaml.lua_encode);
        L.Zsetfieldc(-1, "decode", yaml.lua_decode);

        L.setreadonly(-1, true);
        L.setfield(-2, "yaml");
    }

    { // Base64
        L.newtable();

        L.Zsetfieldc(-1, "encode", base64.lua_encode);
        L.Zsetfieldc(-1, "decode", base64.lua_decode);

        L.setreadonly(-1, true);
        L.setfield(-2, "base64");
    }

    { // Gzip
        L.newtable();

        L.Zsetfieldc(-1, "compress", gzip.lua_compress);
        L.Zsetfieldc(-1, "decompress", gzip.lua_decompress);

        L.setreadonly(-1, true);
        L.setfield(-2, "gzip");
    }

    { // Zlib
        L.newtable();

        L.Zsetfieldc(-1, "compress", zlib.lua_compress);
        L.Zsetfieldc(-1, "decompress", zlib.lua_decompress);

        L.setreadonly(-1, true);
        L.setfield(-2, "zlib");
    }

    { // Flate
        L.newtable();

        L.Zsetfieldc(-1, "compress", flate.lua_compress);
        L.Zsetfieldc(-1, "decompress", flate.lua_decompress);

        L.setreadonly(-1, true);
        L.setfield(-2, "flate");
    }

    { // Lz4
        L.newtable();

        L.Zsetfieldc(-1, "compress", lz4.lua_compress);
        L.Zsetfieldc(-1, "compressFrame", lz4.lua_frame_compress);
        L.Zsetfieldc(-1, "decompress", lz4.lua_decompress);
        L.Zsetfieldc(-1, "decompressFrame", lz4.lua_frame_decompress);

        L.setreadonly(-1, true);
        L.setfield(-2, "lz4");
    }

    { // Zstd
        L.newtable();

        L.Zsetfieldc(-1, "compress", zstd.lua_compress);
        L.Zsetfieldc(-1, "decompress", zstd.lua_decompress);

        L.setreadonly(-1, true);
        L.setfield(-2, "zstd");
    }

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    std.testing.refAllDecls(@This());
}

test "Serde" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"serde.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
