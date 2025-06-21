const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const command = @import("lib.zig");

const AnalysisNavigatorContext = struct {
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,

    const This = @This();

    pub fn getConfig(self: *This, path: []const u8, out_err: ?*?[]const u8) !Zune.Resolvers.Config {
        const allocator = self.allocator;

        const contents = self.dir.readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => return error.NotPresent,
            else => return err,
        };
        defer allocator.free(contents);

        var config = try Zune.Resolvers.Config.parse(Zune.DEFAULT_ALLOCATOR, contents, out_err);
        errdefer config.deinit(Zune.DEFAULT_ALLOCATOR);

        return config;
    }
    pub fn freeConfig(self: *This, config: *Zune.Resolvers.Config) void {
        config.deinit(self.allocator);
    }
    pub fn resolvePathAlloc(_: *This, allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return try Zune.Resolvers.File.resolve(allocator, Zune.STATE.ENV_MAP, &.{ from, to });
    }
};

fn splitArgs(args: []const []const u8) struct { []const []const u8, ?[]const []const u8 } {
    var run_args: []const []const u8 = args;
    var flags: ?[]const []const u8 = null;
    blk: {
        for (args, 0..) |arg, ap| {
            if (arg.len <= 1 or arg[0] != '-') {
                if (ap > 0)
                    flags = args[0..ap];
                run_args = args[ap..];
                break :blk;
            }
        }
        flags = args;
        run_args = &[0][]const u8{};
        break :blk;
    }
    return .{ run_args, flags };
}

fn printPreviewError(padding: []u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    Zune.debug.print("{s}|\n", .{padding});
    _ = std.fmt.bufPrint(padding, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    Zune.debug.print("{s}~ <dim>PreviewError: " ++ fmt ++ "<clear>\n", .{padding} ++ args);
    @memset(padding, ' ');
    Zune.debug.print("{s}|\n", .{padding});
}

fn printPreviewSource(
    allocator: std.mem.Allocator,
    tag: []const u8,
    message: []const u8,
    file: []const u8,
    source: []const u8,
    location: luau.Ast.Location.Location,
) void {
    const line = location.begin.line + 1;
    const padding = std.math.log10(line) + 1;
    const padded_string = allocator.alloc(u8, padding + 1) catch |e| std.debug.panic("{}", .{e});
    defer allocator.free(padded_string);
    @memset(padded_string, ' ');

    Zune.debug.print("<red>{s}<clear>: {s}\n<bold><underline>{s}:{d}:{d}<clear>\n", .{
        tag,
        message,
        file,
        location.begin.line + 1,
        location.begin.column + 1,
    });

    var stream = std.io.fixedBufferStream(source);
    const reader = stream.reader();
    if (line > 1) for (0..@intCast(line - 1)) |_| {
        while (true) {
            if (reader.readByte() catch |e| {
                return printPreviewError(padded_string, line, "Failed to read line: {}", .{e});
            } == '\n') break;
        }
    };

    const line_content = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| {
        return printPreviewError(padded_string, line, "Failed to read line: {}", .{e});
    } orelse {
        return printPreviewError(padded_string, line, "Failed to read line, ended too early", .{});
    };
    defer allocator.free(line_content);

    Zune.debug.print("{s}|\n", .{padded_string});
    _ = std.fmt.bufPrint(padded_string, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    Zune.debug.print("{s}| {s}\n", .{ padded_string, line_content });
    @memset(padded_string, ' ');

    const start_pos = location.begin.column;
    const end_pos = if (location.end.line == location.begin.line)
        location.end.column
    else
        line_content.len - 1;

    const len = (end_pos - start_pos);

    const space_slice = line_content[0..start_pos];

    const buf = allocator.alloc(u8, len) catch |e| std.debug.panic("{}", .{e});
    defer allocator.free(buf);

    @memset(buf, '^');
    @memset(space_slice, ' ');

    Zune.debug.print("{s}| {s}<red>{s}<clear>\n", .{ padded_string, space_slice, buf });
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const Ast = luau.Ast;
    const Analysis = luau.Analysis;

    const FileResolver = Analysis.FileResolver;

    const run_args, const flags = splitArgs(args);

    if (run_args.len == 0)
        return std.debug.print("Usage: zune check [options] <path>\n", .{});

    var definition_files: std.ArrayListUnmanaged([]const u8) = .empty;

    var ignore_zune_defintions = false;
    if (flags) |f| for (f) |flag| {
        if (flag.len < 2)
            continue;
        switch (flag[0]) {
            '-' => switch (flag[1]) {
                '-' => if (std.mem.startsWith(u8, flag, "--definitions=")) {
                    const def_path = flag[14..];
                    if (def_path.len == 0) {
                        std.debug.print("Flag: --definitions, No path provided.\n", .{});
                        std.process.exit(1);
                    }
                    try definition_files.append(allocator, def_path);
                } else if (std.mem.startsWith(u8, flag, "--no-zune")) {
                    ignore_zune_defintions = true;
                } else {
                    std.debug.print("Unknown flag: {s}\n", .{flag});
                    std.process.exit(1);
                },
                else => {
                    std.debug.print("Unknown flag: {s}\n", .{flag});
                    std.process.exit(1);
                },
            },
            else => unreachable,
        }
    };

    Zune.loadConfiguration(std.fs.cwd());

    const FileImpl = struct {
        allocator: std.mem.Allocator,
        dir: std.fs.Dir = std.fs.cwd(),

        const Self = @This();
        pub fn readSource(self: *Self, path: []const u8) ?struct { []const u8, FileResolver.SourceCodeType } {
            const source = self.dir.readFileAlloc(self.allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => {
                    std.debug.print("Error reading source file '{s}': {}\n", .{ path, err });
                    return null;
                },
                error.IsDir => {
                    std.debug.print("Error reading source file '{s}': Is a directory\n", .{path});
                    return null;
                },
                else => @panic(@errorName(err)),
            };
            return .{ source, .Module };
        }

        pub fn resolveModule(self: *Self, from: []const u8, to: []const u8) ?[]const u8 {
            const script_path = blk: {
                var context: AnalysisNavigatorContext = .{
                    .dir = self.dir,
                    .allocator = self.allocator,
                };

                var err_msg: ?[]const u8 = null;
                defer if (err_msg) |err| self.allocator.free(err);
                break :blk Zune.Resolvers.Navigator.navigate(self.allocator, &context, from, to, &err_msg) catch |err| switch (err) {
                    error.SyntaxError, error.AliasNotFound, error.AliasPathNotSupported, error.AliasJumpFail => {
                        std.debug.print("Error resolving module: {s}\n", .{err_msg.?});
                        return null;
                    },
                    error.PathUnsupported => {
                        std.debug.print("must have either \"@\", \"./\", or \"../\" prefix", .{});
                        return null;
                    },
                    else => {
                        std.debug.print("Error resolving module: {}\n", .{err});
                        return null;
                    },
                };
            };
            defer self.allocator.free(script_path);

            var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const result = Zune.Resolvers.File.searchLuauFile(&path_buf, self.dir, script_path) catch |err| switch (err) {
                else => {
                    std.debug.print("Error searching for module '{s}': {}\n", .{ script_path, err });
                    return null;
                },
            };
            defer result.deinit();

            if (result.count > 1) {
                std.debug.print("Module require conflicted:", .{});
                for (result.slice()) |file|
                    std.debug.print(" - {s}{s}\n", .{ script_path, file.ext });
                return null;
            }

            return std.mem.concat(self.allocator, u8, &.{ script_path, result.first().ext }) catch @panic("OutOfMemory");
        }

        pub fn getHumanReadableModuleName(self: *Self, name: []const u8) []const u8 {
            return self.allocator.dupe(u8, name) catch @panic("OutOfMemory");
        }

        pub fn freeString(self: *Self, buf: []const u8) void {
            self.allocator.free(buf);
        }
    };

    const FileImplResolver = FileResolver.FileResolver(FileImpl);

    var file_impl: FileImpl = .{
        .allocator = allocator,
        .dir = std.fs.cwd(),
    };
    const file_resolver = FileImplResolver.init(&file_impl);
    defer file_resolver.deinit();
    const config_resolver = luau.Analysis.GenericConfigResolver.init(.Strict);
    defer config_resolver.deinit();

    const frontend = Analysis.Frontend.init(file_resolver, config_resolver, .{});
    defer frontend.deinit();

    frontend.registerBuiltinGlobals();

    var contentStream = std.io.fixedBufferStream(@import("./setup.zig").luaudefs[0].content);
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();

    try std.compress.gzip.decompress(contentStream.reader(), decompressed.writer());

    if (!ignore_zune_defintions) {
        if (try frontend.loadDefinitionFileWithAlloc(
            allocator,
            decompressed.items,
            "@zune",
            false,
            false,
        )) |*res| {
            defer res.deinit();
            std.debug.print("error: {s} {}\n", .{ res.message, res.location });
            @panic("Bad Zune defintion file, corrupted or outdated");
        }
    }

    for (definition_files.items) |def_file| {
        const def_content = file_impl.dir.readFileAlloc(allocator, def_file, std.math.maxInt(usize)) catch |err| switch (err) {
            error.IsDir => {
                std.debug.print("Error reading definition file '{s}': Is a directory\n", .{def_file});
                return error.IsDir;
            },
            else => {
                std.debug.print("Error reading definition file '{s}': {}\n", .{ def_file, err });
                return err;
            },
        };
        defer allocator.free(def_content);

        var res = try frontend.loadDefinitionFileWithAlloc(
            allocator,
            def_content,
            "@user",
            false,
            false,
        );
        if (res) |*r| {
            defer r.deinit();

            printPreviewSource(allocator, "LoadDefinitionError", r.message, def_file, def_content, r.location);
            std.process.exit(1);
        }
    }

    for (run_args) |file|
        frontend.queueModuleCheck(file);

    var State: struct {
        allocator: std.mem.Allocator,
        file_impl: *FileImpl,
        file_resolver: *FileImplResolver,
        frontend: *Analysis.Frontend.Frontend,
        errored: bool,
    } = .{
        .allocator = allocator,
        .file_impl = &file_impl,
        .file_resolver = file_resolver,
        .frontend = frontend,
        .errored = false,
    };

    const success = frontend.checkQueuedModules(
        &State,
        struct {
            fn checkedModule(state: *@TypeOf(State), name: [:0]const u8) bool {
                switch (state.frontend.getCheckResult(name, false, false, state, struct {
                    fn inner(
                        state_inner: *@TypeOf(State),
                        kind: Analysis.Frontend.CheckResultErrorKind,
                        readableModuleName: [:0]const u8,
                        errorMessage: [:0]const u8,
                        typeName: [:0]const u8,
                        loc: Ast.Location.Location,
                    ) void {
                        _ = kind;
                        const source, const source_type = state_inner.file_impl.readSource(readableModuleName) orelse return;
                        _ = source_type;
                        defer state_inner.file_impl.freeString(source);

                        printPreviewSource(state_inner.allocator, typeName, errorMessage, readableModuleName, source, loc);
                    }
                }.inner)) {
                    .None => {}, // should be unreachable since getCheckResult is called after checkQueuedModules
                    .Success => {},
                    .Error => state.errored = true,
                }
                return true;
            }
        }.checkedModule,
        struct {
            fn checkedModuleError(state_inner: *@TypeOf(State), readableModuleName: [:0]const u8, errMsg: [:0]const u8, loc: Ast.Location.Location) void {
                const source, const source_type = state_inner.file_impl.readSource(readableModuleName) orelse return;
                _ = source_type;
                defer state_inner.file_impl.freeString(source);
                printPreviewSource(state_inner.allocator, "CheckError", errMsg, readableModuleName, source, loc);
            }
        }.checkedModuleError,
    );

    if (!success or State.errored) {
        Zune.debug.print("module check failed.\n", .{});
        std.process.exit(1);
    }
    Zune.debug.print("module checked successfully.\n", .{});
}

pub const Command = command.Command{
    .name = "check",
    .execute = Execute,
    .aliases = null,
};

test "cmdCheck" {
    const allocator = std.testing.allocator;
    {
        const args: []const []const u8 = &.{"test/cli/run.luau"};
        try Execute(allocator, args);
    }
    {
        const args: []const []const u8 = &.{"test/cli/test.luau"};
        try Execute(allocator, args);
    }
}
