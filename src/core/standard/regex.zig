const std = @import("std");
const luau = @import("luau");

const regex = @import("regex");

const Regex = regex.Regex;

const Luau = luau.Luau;

const LuaRegex = struct {
    pub const META = "regex_instance";

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const namecall = L.nameCallAtom() catch return 0;
        var r_ptr = L.toUserdata(Regex, 1) catch return 0;
        if (std.mem.eql(u8, namecall, "match")) {
            const input = L.checkString(2);
            var i: i32 = 1;
            if (try r_ptr.match(input)) |match| {
                L.newTable();
                defer match.deinit();
                const groups = match.groups;
                for (groups) |str| {
                    L.newTable();
                    L.setFieldInteger(-1, "index", @intCast(str.index));
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
                    L.setFieldInteger(-1, "index", @intCast(str.index));
                    L.setFieldLString(-1, "string", str.slice);
                    L.rawSetIndex(-2, i);
                    i += 1;
                }
                return 1;
            }
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
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    pub fn __dtor(reg: *Regex) void {
        reg.deinit();
    }
};

fn regex_new(L: *Luau) !i32 {
    const r_ptr = L.newUserdataDtor(Regex, LuaRegex.__dtor);
    errdefer L.pop(1);

    const r = try Regex.compile(L.allocator(), L.checkString(1));
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

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/regex") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/regex");
    } else L.pop(1);
    L.pop(2);
}

test "Regex" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"regex.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
