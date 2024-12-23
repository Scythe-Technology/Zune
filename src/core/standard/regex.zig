const std = @import("std");
const luau = @import("luau");
const regex = @import("regex");

const luaHelper = @import("../utils/luahelper.zig");

const Regex = regex.Regex;

const Luau = luau.Luau;

pub const LIB_NAME = "regex";

fn lua_regexCaptureSearch(L: *Luau, re: *Regex, input: []const u8, index: *usize, captures: *i32, global: bool) !void {
    var relative_index: usize = 0;
    while (true) {
        if (relative_index >= input.len)
            break;
        if (try re.search(input[relative_index..])) |match| {
            L.newTable();
            defer match.deinit();
            const groups = match.groups;
            if (groups.len == 0) break;
            var i: i32 = 1;
            for (groups) |str| {
                L.newTable();
                L.setFieldInteger(-1, "index", @intCast(1 + index.* + relative_index + str.index));
                L.setFieldLString(-1, "string", str.slice);
                L.rawSetIndex(-2, i);
                i += 1;
            }
            relative_index += match.groups[0].index + match.groups[0].slice.len + 1;
            L.rawSetIndex(-2, captures.*);
            captures.* += 1;
        } else break;
        if (!global)
            break;
    }
    index.* += input.len;
}

const LuaRegex = struct {
    pub const META = "regex_instance";

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        var r_ptr = L.toUserdata(Regex, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        if (std.mem.eql(u8, namecall, "match")) {
            const input = L.checkString(2);
            var i: i32 = 1;
            if (try r_ptr.match(input)) |match| {
                L.newTable();
                defer match.deinit();
                const groups = match.groups;
                for (groups) |str| {
                    L.newTable();
                    L.setFieldInteger(-1, "index", @intCast(1 + str.index));
                    L.setFieldLString(-1, "string", str.slice);
                    L.rawSetIndex(-2, i);
                    i += 1;
                }
                return 1;
            }
        } else if (std.mem.eql(u8, namecall, "search")) {
            const input = L.checkString(2);
            var i: i32 = 1;
            if (try r_ptr.search(input)) |match| {
                L.newTable();
                defer match.deinit();
                const groups = match.groups;
                for (groups) |str| {
                    L.newTable();
                    L.setFieldInteger(-1, "index", @intCast(1 + str.index));
                    L.setFieldLString(-1, "string", str.slice);
                    L.rawSetIndex(-2, i);
                    i += 1;
                }
                return 1;
            }
        } else if (std.mem.eql(u8, namecall, "captures")) {
            const input = L.checkString(2);
            const global = L.optBoolean(3) orelse false;

            var index: usize = 0;
            var captures: i32 = 1;
            L.newTable();

            try lua_regexCaptureSearch(L, r_ptr, input, &index, &captures, global);

            return 1;
        } else if (std.mem.eql(u8, namecall, "isMatch")) {
            const input = L.checkString(2);
            L.pushBoolean(r_ptr.isMatch(input));
            return 1;
        } else if (std.mem.eql(u8, namecall, "format")) {
            const allocator = L.allocator();
            const input = L.checkString(2);
            const fmt = L.checkString(3);
            const formatted = try r_ptr.allocFormat(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushLString(formatted);
            return 1;
        } else if (std.mem.eql(u8, namecall, "replace")) {
            const allocator = L.allocator();
            const input = L.checkString(2);
            const fmt = L.checkString(3);
            const formatted = try r_ptr.allocReplace(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushLString(formatted);
            return 1;
        } else if (std.mem.eql(u8, namecall, "replaceAll")) {
            const allocator = L.allocator();
            const input = L.checkString(2);
            const fmt = L.checkString(3);
            const formatted = try r_ptr.allocReplaceAll(allocator, input, fmt);
            defer allocator.free(formatted);
            L.pushLString(formatted);
            return 1;
        } else return L.ErrorFmt("Unknown method: {s}\n", .{namecall});
        return 0;
    }

    pub fn __dtor(reg: *Regex) void {
        reg.deinit();
    }
};

fn regex_new(L: *Luau) !i32 {
    const flags = L.optString(2) orelse "";

    if (flags.len > 2)
        return L.Error("Too many flags provided");

    var flag: c_int = 0;
    for (flags) |f| switch (f) {
        'i' => flag |= regex.FLAG_IGNORECASE,
        'm' => flag |= regex.FLAG_MULTILINE,
        else => return L.ErrorFmt("Unknown flag: {c}", .{f}),
    };

    const r = try Regex.compile(L.allocator(), L.checkString(1), if (flag == 0) null else flag);

    const r_ptr = L.newUserdataDtor(Regex, LuaRegex.__dtor);

    r_ptr.* = r;

    if (L.getMetatableRegistry(LuaRegex.META) == .table) L.setMetatable(-2) else std.debug.panic("InternalError (Regex Metatable not initialized)", .{});

    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaRegex.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.namecall, LuaRegex.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newTable();

    L.setFieldFn(-1, "new", regex_new);

    L.setReadOnly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Regex" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"regex.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
