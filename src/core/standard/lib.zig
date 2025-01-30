pub const fs = @import("fs/lib.zig");
pub const ffi = @import("ffi.zig");
pub const net = @import("net/lib.zig");
pub const task = @import("task.zig");
pub const luau = @import("luau.zig");
pub const stdio = @import("stdio.zig");
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

test "Std" {
    const ztesting = @import("std").testing;
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(ztesting.allocator, @import("zune-test-files").@"lib.std.test", &.{}, true);

    try ztesting.expect(testResult.failed == 0);
}
