const std = @import("std");
const luau = @import("luau");
const sqlite = @import("sqlite");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");
const tagged = @import("../../tagged.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "sqlite";

const LuaStatement = struct {
    db: *LuaDatabase,
    ref: ?i32,
    statement: sqlite.Statement,
    closed: bool = false,

    pub const META = "sqlite_statement_instance";

    // Placeholder
    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        return 0;
    }

    pub fn loadParams(allocator: std.mem.Allocator, L: *Luau, statement: sqlite.Statement, idx: i32) ![]?sqlite.Value {
        if (L.typeOf(idx) != .table)
            return L.ErrorFmt("Expected table in argument #{d}", .{idx - 1});
        const values = try allocator.alloc(?sqlite.Value, statement.param_list.items.len);
        errdefer allocator.free(values);
        for (statement.param_list.items, 0..) |info, i| {
            L.pushLString(info.name);
            switch (L.getTable(idx)) {
                .number => values[i] = .{ .f64 = L.toNumber(-1) catch unreachable },
                .string => values[i] = .{ .text = L.toString(-1) catch unreachable },
                .buffer => values[i] = .{ .blob = L.toBuffer(-1) catch unreachable },
                .nil => values[i] = null,
                else => return L.ErrorFmt("Unsupported type for parameter {s}", .{info.name}),
            }
        }
        return values;
    }

    fn resultToTable(L: *Luau, statement: sqlite.Statement, res: []const ?sqlite.Value) !void {
        L.newTable();
        for (res, 0..) |value, idx| {
            const name = statement.column_list.items[idx].name;
            if (value) |v| {
                L.pushLString(name);
                switch (v) {
                    .f64 => |n| L.pushNumber(n),
                    .i32 => |n| L.pushInteger(n),
                    .i64 => |n| L.pushNumber(@floatFromInt(n)),
                    .text => |s| L.pushLString(s),
                    .blob => |b| L.pushBuffer(b),
                }
                L.setTable(-3);
            }
        }
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdataTagged(LuaStatement, 1, tagged.SQLITE_STATEMENT) catch unreachable;
        const namecall = L.nameCallAtom() catch return 0;
        const allocator = L.allocator();
        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "all")) {
            if (ptr.closed)
                return L.Error("Statement is closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            var order: i32 = 1;
            L.newTable();
            while (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
                L.rawSetIndex(-2, order);
                order += 1;
            }

            return 1;
        } else if (std.mem.eql(u8, namecall, "get")) {
            if (ptr.closed)
                return L.Error("Statement is closed");
            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res| {
                defer allocator.free(res);
                try resultToTable(L, ptr.statement, res);
            } else {
                ptr.statement.reset();
                L.pushNil();
            }
            return 1;
        } else if (std.mem.eql(u8, namecall, "run")) {
            if (ptr.closed)
                return L.Error("Statement is closed");

            ptr.statement.reset();
            defer ptr.statement.reset();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (ptr.statement.paramSize() > 0)
                params = try loadParams(allocator, L, ptr.statement, 2);

            ptr.statement.bind(params orelse &.{}) catch |err| return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() });

            if (ptr.statement.step(allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.db.getErrorMessage() }),
            }) |res|
                allocator.free(res);

            L.newTable();

            L.setFieldInteger(-1, "lastInsertRowId", @as(i32, @truncate(ptr.db.db.getLastInsertRowId())));
            L.setFieldInteger(-1, "changes", @as(i32, @truncate(ptr.db.db.countChanges())));

            return 1;
        } else if (std.mem.eql(u8, namecall, "finalize")) {
            ptr.close(L);
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn close(ptr: *LuaStatement, L: *Luau) void {
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

    pub fn __dtor(L: *Luau, ptr: *LuaStatement) void {
        ptr.close(L);
    }
};

const LuaDatabase = struct {
    db: sqlite.Database,
    statements: std.ArrayList(i32),
    closed: bool = false,

    pub const META = "sqlite_database_instance";

    // Placeholder
    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
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
        state: *Luau,
        state_ref: ?i32,
    };

    pub fn transactionResumed(ctx: *Transaction, L: *Luau, _: *Scheduler) void {
        const ptr = ctx.ptr;
        const command = switch (L.status()) {
            .ok => "COMMIT",
            else => "ROLLBACK",
        };
        L.unref(ctx.state_ref orelse unreachable);
        ctx.state_ref = null;
        const state = ctx.state;
        ptr.db.exec(command, &.{}) catch |err| {
            switch (err) {
                error.OutOfMemory => state.pushString(@errorName(err)),
                else => state.pushFmtString("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }) catch state.pushString("OutOfMemory"),
            }
            _ = Scheduler.resumeStateError(state, null) catch {};
            return;
        };
        if (L.status() != .ok) {
            L.xPush(state, 1);
            _ = Scheduler.resumeStateError(state, null) catch {};
        } else {
            _ = Scheduler.resumeState(state, null, 0) catch {};
        }
    }

    pub fn transactionResumedDtor(ctx: *Transaction, L: *Luau, _: *Scheduler) void {
        if (ctx.state_ref) |ref|
            L.unref(ref);
    }

    pub fn transaction(L: *Luau, scheduler: *Scheduler) !i32 {
        const ptr = L.toUserdataTagged(LuaDatabase, Luau.upvalueIndex(1), tagged.SQLITE_DATABASE) catch unreachable;
        const kind: TransactionKind = @enumFromInt(L.toInteger(Luau.upvalueIndex(3)) catch unreachable);
        const activator = switch (kind) {
            .None => "BEGIN",
            .Deferred => "BEGIN DEFERRED",
            .Immediate => "BEGIN IMMEDIATE",
            .Exclusive => "BEGIN EXCLUSIVE",
        };
        ptr.db.exec(activator, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
        };
        const args = L.getTop();
        const ML = L.newThread();
        L.xPush(ML, Luau.upvalueIndex(2));
        if (args > 0)
            for (1..@intCast(args + 1)) |i| {
                L.xPush(ML, @intCast(i));
            };

        _ = L.pushThread();
        const ref = L.ref(-1) catch unreachable;
        L.pop(1); // drop: thread

        const status = ML.resumeThread(L, args) catch |err| {
            L.unref(ref);
            ptr.db.exec("ROLLBACK", &.{}) catch |sql_err| switch (sql_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ sql_err, ptr.db.getErrorMessage() }),
            };
            switch (err) {
                error.Runtime => {
                    ML.xPush(L, -1);
                    return error.RaiseLuauError;
                },
                else => return err,
            }
        };

        if (status == .yield) {
            if (scheduler.awaitResult(Transaction, .{
                .ptr = ptr,
                .state = L,
                .state_ref = ref,
            }, ML, transactionResumed, transactionResumedDtor)) |_|
                return L.yield(0);
        } else {
            L.unref(ref);
            ptr.db.exec("COMMIT", &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
        }
        return 0;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaDatabase, 1) catch unreachable;
        const namecall = L.nameCallAtom() catch return 0;

        const allocator = L.allocator();

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "query")) {
            if (ptr.closed)
                return L.Error("Database is closed");
            const query = L.checkString(2);
            try ptr.statements.ensureTotalCapacity(ptr.statements.items.len + 1);
            const statement = ptr.db.prepare(query) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidParameter => return L.ErrorFmt("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
            const stmt_ptr = L.newUserdataTaggedWithMetatable(LuaStatement, tagged.SQLITE_STATEMENT);
            const ref = L.ref(-1) catch unreachable;
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
                return L.Error("Database is closed");
            const query = L.checkString(2);

            const stmt = ptr.db.prepare(query) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidParameter => return L.ErrorFmt("SQLite Query Error ({}): must have '$', ':', '?', or '@'", .{err}),
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
            defer stmt.deinit();

            var params: ?[]?sqlite.Value = null;
            defer if (params) |p| allocator.free(p);
            if (stmt.paramSize() > 0)
                params = try LuaStatement.loadParams(allocator, L, stmt, 3);

            stmt.exec(allocator, params orelse &.{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return L.ErrorFmt("SQLite Error ({}): {s}", .{ err, ptr.db.getErrorMessage() }),
            };
        } else if (std.mem.eql(u8, namecall, "transaction")) {
            L.checkType(2, .function);
            const kind_str = L.optString(3);
            const kind: TransactionKind = if (kind_str) |str|
                TransactionMap.get(str) orelse return L.ErrorFmt("Unknown transaction kind: {s}.", .{str})
            else
                .None;
            L.pushValue(1);
            L.pushValue(2);
            L.pushInteger(@intFromEnum(kind));
            L.pushClosure(luau.toCFn(Scheduler.toSchedulerEFn(transaction)), "Transaction", 3);
            return 1;
        } else if (std.mem.eql(u8, namecall, "close")) {
            if (!(L.optBoolean(2) orelse false)) {
                ptr.close(L) catch {};
            } else {
                ptr.close(L) catch {
                    return L.ErrorFmt("SQLite Error: {s}", .{ptr.db.getErrorMessage()});
                };
            }
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn close(ptr: *LuaDatabase, L: *Luau) !void {
        if (ptr.closed)
            return;
        defer {
            ptr.closed = true;
            ptr.statements.deinit();
        }
        Luau.sys.luaD_checkstack(L, 2);
        Luau.sys.luaD_expandstacklimit(L, 2);
        if (ptr.statements.items.len > 0) {
            var i = ptr.statements.items.len;
            while (i > 0) {
                i -= 1;
                const ref = ptr.statements.swapRemove(i);
                defer L.pop(1);
                if (L.rawGetIndex(luau.REGISTRYINDEX, ref) != .userdata)
                    continue;
                const stmt_ptr = L.toUserdataTagged(LuaStatement, -1, tagged.SQLITE_STATEMENT) catch continue;
                stmt_ptr.close(L);
            }
        }
        try ptr.db.close();
    }

    pub fn __dtor(L: *Luau, ptr: *LuaDatabase) void {
        ptr.close(L) catch {};
    }
};

fn sqlite_open(L: *Luau) !i32 {
    const allocator = L.allocator();
    var db: sqlite.Database = undefined;
    if (L.optString(1)) |path| {
        db = if (std.mem.eql(u8, path, ":MEMORY:") or std.mem.eql(u8, path, ":memory:"))
            try sqlite.Database.open(allocator, .{})
        else
            try sqlite.Database.open(allocator, .{ .path = path });
    } else {
        db = try sqlite.Database.open(allocator, .{});
    }
    const ptr = L.newUserdataTaggedWithMetatable(LuaDatabase, tagged.SQLITE_DATABASE);
    ptr.* = .{
        .db = db,
        .statements = std.ArrayList(i32).init(allocator),
    };
    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaDatabase.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaDatabase.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaDatabase.__namecall); // metatable.__namecall

        L.setUserdataDtor(LuaDatabase, tagged.SQLITE_DATABASE, LuaDatabase.__dtor);
        L.setUserdataMetatable(tagged.SQLITE_DATABASE, -1);
    }
    {
        L.newMetatable(LuaStatement.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaStatement.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaStatement.__namecall); // metatable.__namecall

        L.setUserdataDtor(LuaStatement, tagged.SQLITE_STATEMENT, LuaStatement.__dtor);
        L.setUserdataMetatable(tagged.SQLITE_STATEMENT, -1);
    }

    L.newTable();

    L.setFieldFn(-1, "open", sqlite_open);

    L.setReadOnly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "SQLite" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"sqlite.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
