const std = @import("std");
const luau = @import("luau");
const pcre2 = @import("regex");

const luaHelper = @import("../utils/luahelper.zig");
const MethodMap = @import("../utils/method_map.zig");
const tagged = @import("../../tagged.zig");

const VM = luau.VM;

const TAG_REGEX_COMPILED = tagged.Tags.get("REGEX_COMPILED").?;

pub const LIB_NAME = "regex";

const LuaRegex = struct {
    code: *pcre2.Code,

    pub fn match(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        if (try self.code.match(allocator, input)) |m| {
            defer m.free(allocator);
            L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                L.rawseti(-2, @intCast(i));
            }
            return 1;
        }
        return 0;
    }

    pub fn search(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        if (try self.code.search(allocator, input)) |m| {
            defer m.free(allocator);
            L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                L.rawseti(-2, @intCast(i));
            }
            return 1;
        }
        return 0;
    }

    pub fn captures(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([]const u8, 2, null);
        const global = L.Loptboolean(3, false);

        L.newtable();

        var iter = try self.code.searchIterator(input);
        defer iter.free();
        var captures_count: i32 = 1;
        while (try iter.next(allocator)) |m| {
            defer m.free(allocator);
            L.createtable(@intCast(m.captures.len), 0);
            for (m.captures, 1..) |capture, i| {
                if (capture) |c| {
                    L.Zpushvalue(.{
                        .index = 1 + c.index,
                        .string = c.slice,
                        .name = c.name,
                    });
                } else {
                    L.pushnil();
                }
                L.rawseti(-2, @intCast(i));
            }
            L.rawseti(-2, captures_count);
            captures_count += 1;
            if (!global)
                break;
        }

        return 1;
    }

    pub fn isMatch(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const input = try L.Zcheckvalue([]const u8, 2, null);
        L.pushboolean(try self.code.isMatch(input));
        return 1;
    }

    pub fn format(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocFormat(allocator, input, fmt);
        defer allocator.free(formatted);
        L.pushlstring(formatted);
        return 1;
    }

    pub fn replace(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocReplace(allocator, input, fmt);
        defer allocator.free(formatted);
        L.pushlstring(formatted);
        return 1;
    }

    pub fn replaceAll(self: *LuaRegex, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const input = try L.Zcheckvalue([:0]const u8, 2, null);
        const fmt = try L.Zcheckvalue([:0]const u8, 3, null);
        const formatted = try self.code.allocReplaceAll(allocator, input, fmt);
        defer allocator.free(formatted);
        L.pushlstring(formatted);
        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(LuaRegex, TAG_REGEX_COMPILED, .{
        .{ "match", match },
        .{ "search", search },
        .{ "captures", captures },
        .{ "isMatch", isMatch },
        .{ "format", format },
        .{ "replace", replace },
        .{ "replaceAll", replaceAll },
    });

    pub fn __dtor(L: *VM.lua.State, reg: **pcre2.Code) void {
        _ = L;
        reg.*.deinit();
    }
};

fn regex_create(L: *VM.lua.State) !i32 {
    const flags = L.tolstring(2) orelse "";

    if (flags.len > 2)
        return L.Zerror("Too many flags provided");

    var flag: u32 = 0;
    for (flags) |f| switch (f) {
        'i' => flag |= pcre2.Options.CASELESS,
        'm' => flag |= pcre2.Options.MULTILINE,
        'u' => flag |= pcre2.Options.UTF,
        else => return L.Zerrorf("Unknown flag: {c}", .{f}),
    };

    var pos: usize = 0;
    const r = try pcre2.compile(try L.Zcheckvalue([]const u8, 1, null), flag, &pos);
    const ptr = L.newuserdatataggedwithmetatable(*pcre2.Code, TAG_REGEX_COMPILED);
    ptr.* = r;
    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Znewmetatable(@typeName(LuaRegex), .{
            .__metatable = "Metatable is locked",
        });
        LuaRegex.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_REGEX_COMPILED);
        L.setuserdatadtor(*pcre2.Code, TAG_REGEX_COMPILED, LuaRegex.__dtor);
    }

    L.Zpushvalue(.{
        .create = regex_create,
    });
    L.setreadonly(-1, true);

    luaHelper.registerModule(L, LIB_NAME);
}

test "regex" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/regex.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
