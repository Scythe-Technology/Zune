const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try std.io.getStdErr().writeAll("Usage: <FilePath> <FilePath>\n");
        std.process.exit(1);
    }

    const file = try std.fs.openFileAbsolute(args[1], .{
        .mode = .read_only,
    });
    defer file.close();

    const compressed_file = try std.fs.createFileAbsolute(args[2], .{});
    defer compressed_file.close();

    try std.compress.gzip.compress(file.reader(), compressed_file.writer(), .{});

    std.process.exit(0);
}
