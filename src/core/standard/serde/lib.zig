const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const gzip = @import("gzip.zig");
const zlib = @import("zlib.zig");
const lz4 = @import("lz4.zig");

const Luau = luau.Luau;

pub fn loadLib(L: *Luau) void {
    L.newTable();

    { // Json
        L.newTable();

        L.setFieldFn(-1, "encode", json.lua_encode);
        L.setFieldFn(-1, "decode", json.lua_decode);

        L.setFieldAhead(-1, "json");
    }

    { // Toml
        L.newTable();

        L.setFieldFn(-1, "encode", toml.lua_encode);
        L.setFieldFn(-1, "decode", toml.lua_decode);

        L.setFieldAhead(-1, "toml");
    }

    { // Yaml
        L.newTable();

        L.setFieldFn(-1, "encode", yaml.lua_encode);
        L.setFieldFn(-1, "decode", yaml.lua_decode);

        L.setFieldAhead(-1, "yaml");
    }

    { // Gzip
        L.newTable();

        L.setFieldFn(-1, "compress", gzip.lua_compress);
        L.setFieldFn(-1, "decompress", gzip.lua_decompress);

        L.setFieldAhead(-1, "gzip");
    }

    { // Zlib
        L.newTable();

        L.setFieldFn(-1, "compress", zlib.lua_compress);
        L.setFieldFn(-1, "decompress", zlib.lua_decompress);

        L.setFieldAhead(-1, "zlib");
    }

    { // Lz4
        L.newTable();

        L.setFieldFn(-1, "compress", lz4.lua_compress);
        L.setFieldFn(-1, "decompress", lz4.lua_decompress);

        L.setFieldAhead(-1, "lz4");
    }

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/serde") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/serde");
    } else L.pop(1);
    L.pop(2);
}

test {
    std.testing.refAllDecls(@This());
}

test "Serde" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, "test/standard/serde/init.test.luau", &.{});

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
