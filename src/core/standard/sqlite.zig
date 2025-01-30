const std = @import("std");
const luau = @import("luau");
const sqlite = @import("sqlite");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");
const tagged = @import("../../tagged.zig");

const VM = luau.VM;

pub const LIB_NAME = "sqlite";

const LuaStatement = struct {
    db: *LuaDatabase,
    ref: ?i32,
    statement: sqlite.Statement,
    closed: bool = false,

    pub const META = "sqlite_statement_instance";

    // Placeholder
    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        return 0;
    }

    pub fn loadParams(allocator: std.mem.Allocator, L: *VM.lua.State, statement: sqlite.Statement, idx: i32) ![]?sqlite.Value {
        if (L.typeOf(idx) != .Table)
            return L.Zerrorf("Expected table in argument #{d}", .{idx - 1});
        const values = try allocator.alloc(?sqlite.Value, statement.param_list.items.len);
        errdefer allocator.free(values);
        for (statement.param_list.items, 0..) |info, i| {
            L.pushlstring(info.name);
            switch (L.gettable(idx)) {
                .Number => values[i] = .{ .f64 = L.tonumber(-1) orelse unreachable },
                .String => values[i] = .{ .text = L.tostring(-1) orelse unreachable },
                .Buffer => values[i] = .{ .blob = L.tobuffer(-1) orelse unreachable },
                .Nil => values[i] = null,
                else => return L.Zerrorf("Unsupported type for parameter {s}", .{info.name}),
            }
        }
        return values;
    }

    fn resultToTable(L: *VM.lua.State, statement: sqlite.Statement, res: []const ?sqlite.Value) !void {
        L.newtable();
        for (res, 0..) |value, idx| {
            const name = statement.column_list.items[idx].name;
            if (value) |v| {
                L.pushlstring(name);
                switch (v) {
                    .f64 => |n| L.pushnumber(n),
                    .i32 => |n| L.pushinteger(n),
                    .i64 => |n| L.pushnumber(@floatFromInt(n)),
                    .text => |s| L.pushlstring(s),
                    .blob => |b| L.Zpushbuffer(b),
                }
                L.settable(-3);
            }
        }
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        const ptr = L.touserdatatagged(LuaStatement, 1, tagged.SQLITE_STATEMENT) orelse unreachable;
        const namecall = L.namecallstr() orelse return 0;
        const allocator = luau.getallocator(L);
        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "all")) {
            if (ptr.closed)
                return L.Zerror("Statement is closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            var order: i32 = 1;
            L.newtable();
            while (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
                L.rawseti(-2, order);
                order += 1;
            }

            return 1;
        } else if (std.mem.eql(u8, namecall, "get")) {
            if (ptr.closed)
                return L.Zerror("Statement is closed");
            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
            } else {
                ptr.statement.reset();
                L.pushnil();
            }
            return 1;
        } else if (std.mem.eql(u8, namecall, "run")) {
            if (ptr.closed)
                return L.Zerror("Statement is closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res|
                allocator.free(res);

            L.newtable();

            L.Zsetfield(-1, "lastInsertRowId", @as(i32, @truncate(ptr.db.db.getLastInsertRowId())));
            L.Zsetfield(-1, "changes", @as(i32, @truncate(ptr.db.db.countChanges())));

            return 1;
        } else if (std.mem.eql(u8, namecall, "finalize")) {
            ptr.close(L);
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn close(ptr: *LuaStatement, L: *VM.lua.State) void {
        if (ptr.closed)
            return;
        defer ptr.statement.deinit();
        ptr.closed = true;
        if (ptr.ref) |ref| {
            defer L.unref(ref);
            if (ptr.db.closed)
                return;
            for (ptr.db.statements.items, 0..) |saved_ref, idx| {
                if (saved_ref != ref)
                    continue;
                _ = ptr.db.statements.orderedRemove(idx);
                break;
            }
        }
        ptr.ref = null;
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaStatement) void {
        ptr.close(L);
    }
};

const LuaDatabase = struct {
    db: sqlite.Database,
    statements: std.ArrayList(i32),
    closed: bool = false,

    pub const META = "sqlite_database_instance";

    // Placeholder
    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        return 0;
    }

    const TransactionKind = enum {
        None,
        Deferred,
        Immediate,
        Exclusive,
    };
    const TransactionMap = std.StaticStringMap(TransactionKind).initComptime(.{
        .{ "deferred", .Deferred },
        .{ "immediate", .Immediate },
        .{ "exclusive", .Exclusive },
    });

    const Transaction = struct {
        ptr: *LuaDatabase,
        state: *VM.lua.State,
        state_ref: ?i32,
    };

    pub fn transactionResumed(ctx: *Transaction, L: *VM.lua.State, _: *Scheduler) void {
        const ptr = ctx.ptr;
        const command = switch (L.status()) {
            .Ok => "COMMIT",
            else => "ROLLBACK",
        };
        L.unref(ctx.state_ref orelse unreachable);
        ctx.state_ref = null;
        const state = ctx.state;
        ptr.db.exec(command, &.{}) catch |err| {
            switch (err) {
                error.OutOfMemory => state.pushstring(@errorName(err)),
                else => state.pushfstring("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            }
            _ = Scheduler.resumeStateError(state, null) catch {};
            return;
        };
        if (L.status() != .Ok) {
            L.xpush(state, 1);
            _ = Scheduler.resumeStateError(state, null) catch {};
        } else {
            _ = Scheduler.resumeState(state, null, 0) catch {};
        }
    }

    pub fn transactionResumedDtor(ctx: *Transaction, L: *VM.lua.State, _: *Scheduler) void {
        if (ctx.state_ref) |ref|
            L.unref(ref);
    }

    pub fn transaction(L: *VM.lua.State) !i32 {
        const scheduler = Scheduler.getScheduler(L);

        const ptr = L.touserdatatagged(LuaDatabase, VM.lua.upvalueindex(1), tagged.SQLITE_DATABASE) orelse unreachable;
        const kind: TransactionKind = @enumFromInt(L.tointeger(VM.lua.upvalueindex(3)) orelse unreachable);
        const activator = switch (kind) {
            .None => "BEGIN",
            .Deferred => "BEGIN DEFERRED",
            .Immediate => "BEGIN IMMEDIATE",
            .Exclusive => "BEGIN EXCLUSIVE",
        };
        ptr.db.exec(activator, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
        };
        const args = L.gettop();
        const ML = L.newthread();
        L.xpush(ML, VM.lua.upvalueindex(2));
        if (args > 0)
            for (1..@intCast(args + 1)) |i| {
                L.xpush(ML, @intCast(i));
            };

        _ = L.pushthread();
        const ref = L.ref(-1) orelse unreachable;
        L.pop(1); // drop: thread

        const status = Scheduler.resumeState(ML, L, @intCast(args)) catch |err| {
            L.unref(ref);
            ptr.db.exec("ROLLBACK", &.{}) catch |sql_err| switch (sql_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ sql_err, ptr.db.getErrorMessage() }),
            };
            switch (err) {
                error.Runtime => {
                    ML.xpush(L, -1);
                    return error.RaiseLuauError;
                },
                else => return err,
            }
        };

        if (status == .Yield) {
            if (scheduler.awaitResult(Transaction, .{
                .ptr = ptr,
                .state = L,
                .state_ref = ref,
            }, ML, transactionResumed, transactionResumedDtor, .User)) |_|
                return L.yield(0);
        } else {
            L.unref(ref);
            ptr.db.exec("COMMIT", &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
        }
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        const ptr = L.touserdata(LuaDatabase, 1) orelse unreachable;
        const namecall = L.namecallstr() orelse return 0;

        const allocator = luau.getallocator(L);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "query")) {
            if (ptr.closed)
                return L.Zerror("Database is closed");
            const query = L.Lcheckstring(2);
            try ptr.statements.ensureTotalCapacity(ptr.statements.items.len + 1);
            const statement = ptr.db.prepare(query) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidParameter => return L.Zerrorf("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
            const stmt_ptr = L.newuserdatataggedwithmetatable(LuaStatement, tagged.SQLITE_STATEMENT);
            const ref = L.ref(-1) orelse unreachable;
            ptr.statements.append(ref) catch unreachable; // should have enough capacity
            stmt_ptr.* = .{
                .db = ptr,
                .ref = ref,
                .statement = statement,
                .closed = false,
            };
            return 1;
        } else if (std.mem.eql(u8, namecall, "exec")) {
            if (ptr.closed)
                return L.Zerror("Database is closed");
            const query = L.Lcheckstring(2);

            const stmt = ptr.db.prepare(query) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidParameter => return L.Zerrorf("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
            defer stmt.deinit();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (stmt.paramSize() > 0)
                params = try LuaStatement.loadParams(allocator, L, stmt, 3);

            stmt.exec(allocator, params orelse &.{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.Zerrorf("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
        } else if (std.mem.eql(u8, namecall, "transaction")) {
            L.Lchecktype(2, .Function);
            const kind_str = L.tostring(3);
            const kind: TransactionKind = if (kind_str) |str|
                TransactionMap.get(str) orelse return L.Zerrorf("Unknown transaction kind: {s}.", .{str})
            else
                .None;
            L.pushvalue(1);
            L.pushvalue(2);
            L.pushinteger(@intFromEnum(kind));
            L.pushcclosure(VM.zapi.toCFn(transaction), "Transaction", 3);
            return 1;
        } else if (std.mem.eql(u8, namecall, "close")) {
            if (!L.Loptboolean(2, false)) {
                ptr.close(L) catch {};
            } else {
                ptr.close(L) catch {
                    return L.Zerrorf("SQLite Error: {s}", .{ptr.db.getErrorMessage()});
                };
            }
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn close(ptr: *LuaDatabase, L: *VM.lua.State) !void {
        if (ptr.closed)
            return;
        defer {
            ptr.closed = true;
            ptr.statements.deinit();
        }
        luau.sys.luaD_checkstack(L, 2);
        luau.sys.luaD_expandstacklimit(L, 2);
        if (ptr.statements.items.len > 0) {
            var i = ptr.statements.items.len;
            while (i > 0) {
                i -= 1;
                const ref = ptr.statements.swapRemove(i);
                defer L.pop(1);
                if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) != .Userdata)
                    continue;
                const stmt_ptr = L.touserdatatagged(LuaStatement, -1, tagged.SQLITE_STATEMENT) orelse continue;
                stmt_ptr.close(L);
            }
        }
        try ptr.db.close();
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaDatabase) void {
        ptr.close(L) catch {};
    }
};

fn sqlite_open(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    var db: sqlite.Database = undefined;
    if (L.tolstring(1)) |path| {
        db = if (std.mem.eql(u8, path, ":MEMORY:") or std.mem.eql(u8, path, ":memory:"))
            try sqlite.Database.open(allocator, .{})
        else
            try sqlite.Database.open(allocator, .{ .path = path });
    } else {
        db = try sqlite.Database.open(allocator, .{});
    }
    const ptr = L.newuserdatataggedwithmetatable(LuaDatabase, tagged.SQLITE_DATABASE);
    ptr.* = .{
        .db = db,
        .statements = std.ArrayList(i32).init(allocator),
    };
    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaDatabase.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaDatabase.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaDatabase.__namecall); // metatable.__namecall

        L.setuserdatadtor(LuaDatabase, tagged.SQLITE_DATABASE, LuaDatabase.__dtor);
        L.setuserdatametatable(tagged.SQLITE_DATABASE, -1);
    }
    {
        _ = L.Lnewmetatable(LuaStatement.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaStatement.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaStatement.__namecall); // metatable.__namecall

        L.setuserdatadtor(LuaStatement, tagged.SQLITE_STATEMENT, LuaStatement.__dtor);
        L.setuserdatametatable(tagged.SQLITE_STATEMENT, -1);
    }

    L.newtable();

    L.Zsetfieldfn(-1, "open", sqlite_open);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "SQLite" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"sqlite.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
