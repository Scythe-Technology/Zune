pub const fs = @import("fs/lib.zig");
pub const io = @import("io.zig");
pub const ffi = @import("ffi.zig");
pub const net = @import("net/lib.zig");
pub const task = @import("task.zig");
pub const luau = @import("luau.zig");
pub const regex = @import("regex.zig");
pub const serde = @import("serde/lib.zig");
pub const sqlite = @import("sqlite.zig");
pub const crypto = @import("crypto/lib.zig");
pub const process = @import("process.zig");
pub const testing = @import("testing.zig");
pub const datetime = @import("datetime/lib.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "@std" {
    const std = @import("std");
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("lib/std.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
}
