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
const lz4 = @import("lz4.zig");
const zstd = @import("zstd.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "serde";

pub fn loadLib(L: *Luau) void {
    L.newTable();

    { // Json
        L.newTable();

        L.setFieldFn(-1, "encode", json.LuaEncoder(.JSON));
        L.setFieldFn(-1, "decode", json.LuaDecoder(.JSON));

        json.lua_setprops(L);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "json");
    }

    { // Json5
        L.newTable();

        L.setFieldFn(-1, "encode", json.LuaEncoder(.JSON5));
        L.setFieldFn(-1, "decode", json.LuaDecoder(.JSON5));

        _ = L.getField(-2, "json");

        _ = L.getField(-1, "Indents");
        L.setField(-3, "Indents");

        _ = L.getField(-1, "Values");
        L.setField(-3, "Values");

        L.pop(1);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "json5");
    }

    { // Toml
        L.newTable();

        L.setFieldFn(-1, "encode", toml.lua_encode);
        L.setFieldFn(-1, "decode", toml.lua_decode);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "toml");
    }

    { // Yaml
        L.newTable();

        L.setFieldFn(-1, "encode", yaml.lua_encode);
        L.setFieldFn(-1, "decode", yaml.lua_decode);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "yaml");
    }

    { // Base64
        L.newTable();

        L.setFieldFn(-1, "encode", base64.lua_encode);
        L.setFieldFn(-1, "decode", base64.lua_decode);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "base64");
    }

    { // Gzip
        L.newTable();

        L.setFieldFn(-1, "compress", gzip.lua_compress);
        L.setFieldFn(-1, "decompress", gzip.lua_decompress);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "gzip");
    }

    { // Zlib
        L.newTable();

        L.setFieldFn(-1, "compress", zlib.lua_compress);
        L.setFieldFn(-1, "decompress", zlib.lua_decompress);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "zlib");
    }

    { // Lz4
        L.newTable();

        L.setFieldFn(-1, "compress", lz4.lua_compress);
        L.setFieldFn(-1, "compressFrame", lz4.lua_frame_compress);
        L.setFieldFn(-1, "decompress", lz4.lua_decompress);
        L.setFieldFn(-1, "decompressFrame", lz4.lua_frame_decompress);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "lz4");
    }

    { // Zstd
        L.newTable();

        L.setFieldFn(-1, "compress", zstd.lua_compress);
        L.setFieldFn(-1, "decompress", zstd.lua_decompress);

        L.setReadOnly(-1, true);
        L.setFieldAhead(-1, "zstd");
    }

    L.setReadOnly(-1, true);
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
