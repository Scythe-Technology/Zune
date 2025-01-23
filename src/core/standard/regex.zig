const std = @import("std");
const luau = @import("luau");
const regex = @import("regex");

const luaHelper = @import("../utils/luahelper.zig");

const Regex = regex.Regex;

const VM = luau.VM;

pub const LIB_NAME = "regex";

fn lua_regexCaptureSearch(L: *VM.lua.State, re: *Regex, input: []const u8, index: *usize, captures: *i32, global: bool) !void {
    var relative_index: usize = 0;
    while (true) {
        if (relative_index >= input.len)
            break;
        if (try re.search(input[relative_index..])) |match| {
            L.newtable();
            defer match.deinit();
            const groups = match.groups;
            if (groups.len == 0) break;
            var i: i32 = 1;
            for (groups) |str| {
                L.newtable();
                L.Zsetfield(-1, "index", 1 + index.* + relative_index + str.index);
                L.Zsetfield(-1, "string", str.slice);
                L.rawseti(-2, i);
                i += 1;
            }
            relative_index += match.groups[0].index + match.groups[0].slice.len + 1;
            L.rawseti(-2, captures.*);
            captures.* += 1;
        } else break;
        if (!global)
            break;
    }
    index.* += input.len;
}

const LuaRegex = struct {
    pub const META = "regex_instance";

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        var r_ptr = L.touserdata(Regex, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        if (std.mem.eql(u8, namecall, "match")) {
            const input = L.Lcheckstring(2);
            var i: i32 = 1;
            if (try r_ptr.match(input)) |match| {
                L.newtable();
                defer match.deinit();
                const groups = match.groups;
                for (groups) |str| {
                    L.newtable();
                    L.Zsetfield(-1, "index", 1 + str.index);
                    L.Zsetfield(-1, "string", str.slice);
                    L.rawseti(-2, i);
                    i += 1;
                }
                return 1;
            }
        } else if (std.mem.eql(u8, namecall, "search")) {
            const input = L.Lcheckstring(2);
            var i: i32 = 1;
            if (try r_ptr.search(input)) |match| {
                L.newtable();
                defer match.deinit();
                const groups = match.groups;
                for (groups) |str| {
                    L.newtable();
                    L.Zsetfield(-1, "index", 1 + str.index);
                    L.Zsetfield(-1, "string", str.slice);
                    L.rawseti(-2, i);
                    i += 1;
                }
                return 1;
            }
        } else if (std.mem.eql(u8, namecall, "captures")) {
            const input = L.Lcheckstring(2);
            const global = L.Loptboolean(3, false);

            var index: usize = 0;
            var captures: i32 = 1;
            L.newtable();

            try lua_regexCaptureSearch(L, r_ptr, input, &index, &captures, global);

            return 1;
        } else if (std.mem.eql(u8, namecall, "isMatch")) {
            const input = L.Lcheckstring(2);
            L.pushboolean(r_ptr.isMatch(input));
            return 1;
        } else if (std.mem.eql(u8, namecall, "format")) {
            const allocator = luau.getallocator(L);
            const input = L.Lcheckstring(2);
            const fmt = L.Lcheckstring(3);
            const formatted = try r_ptr.allocFormat(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushlstring(formatted);
            return 1;
        } else if (std.mem.eql(u8, namecall, "replace")) {
            const allocator = luau.getallocator(L);
            const input = L.Lcheckstring(2);
            const fmt = L.Lcheckstring(3);
            const formatted = try r_ptr.allocReplace(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushlstring(formatted);
            return 1;
        } else if (std.mem.eql(u8, namecall, "replaceAll")) {
            const allocator = luau.getallocator(L);
            const input = L.Lcheckstring(2);
            const fmt = L.Lcheckstring(3);
            const formatted = try r_ptr.allocReplaceAll(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushlstring(formatted);
            return 1;
        } else return L.Zerrorf("Unknown method: {s}\n", .{namecall});
        return 0;
    }

    pub fn __dtor(reg: *Regex) void {
        reg.deinit();
    }
};

fn regex_new(L: *VM.lua.State) !i32 {
    const flags = L.tolstring(2) orelse "";

    if (flags.len > 2)
        return L.Zerror("Too many flags provided");

    var flag: c_int = 0;
    for (flags) |f| switch (f) {
        'i' => flag |= regex.FLAG_IGNORECASE,
        'm' => flag |= regex.FLAG_MULTILINE,
        else => return L.Zerrorf("Unknown flag: {c}", .{f}),
    };

    const r = try Regex.compile(luau.getallocator(L), L.Lcheckstring(1), if (flag == 0) null else flag);

    const r_ptr = L.newuserdatadtor(Regex, LuaRegex.__dtor);

    r_ptr.* = r;

    if (L.Lgetmetatable(LuaRegex.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Regex Metatable not initialized)", .{});

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaRegex.META);

        L.Zsetfieldc(-1, luau.Metamethods.namecall, LuaRegex.__namecall); // metatable.__namecall

        L.Zsetfieldc(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newtable();

    L.Zsetfieldc(-1, "new", regex_new);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Regex" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"regex.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
