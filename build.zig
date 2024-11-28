const std = @import("std");
const builtin = @import("builtin");

fn compressFile(b: *std.Build, exe: *std.Build.Step.Compile, file: []const u8, out_file: []const u8) *std.Build.Step.Run {
    const embedded_compressor_run = b.addRunArtifact(exe);

    embedded_compressor_run.addArg(b.path(file).getPath(b));
    embedded_compressor_run.addArg(b.path(out_file).getPath(b));

    return embedded_compressor_run;
}

fn compileFile(b: *std.Build, exe: *std.Build.Step.Compile, file: []const u8, out_file: []const u8) *std.Build.Step.Run {
    const embedded_compiler_run = b.addRunArtifact(exe);

    embedded_compiler_run.addArg(b.path(file).getPath(b));
    embedded_compiler_run.addArg(b.path(out_file).getPath(b));

    return embedded_compiler_run;
}

fn compressRecursive(b: *std.Build, exe: *std.Build.Step.Compile, step: *std.Build.Step, dependentStep: *std.Build.Step, path: []const u8) !void {
    const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and entry.name.len > 2 and !std.mem.eql(u8, entry.name[entry.name.len - 3 ..], ".gz")) {
            const file_name = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, entry.name });
            defer b.allocator.free(file_name);
            const file_name_with_ext = try std.mem.concat(b.allocator, u8, &[_][]const u8{ entry.name, ".gz" });
            defer b.allocator.free(file_name_with_ext);
            const out_file_name = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, file_name_with_ext });
            defer b.allocator.free(out_file_name);
            const run = compressFile(b, exe, file_name, out_file_name);
            run.step.dependOn(dependentStep);
            step.dependOn(&run.step);
        } else if (entry.kind == .directory) {
            const dir_path = try std.fs.path.resolve(b.allocator, &[_][]const u8{ path, entry.name });
            defer b.allocator.free(dir_path);
            try compressRecursive(b, exe, step, dependentStep, dir_path);
        }
    }
}

fn getPackageVersion(b: *std.Build) ![]const u8 {
    var tree = try std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon);
    defer tree.deinit(b.allocator);
    const version = tree.tokenSlice(tree.nodes.items(.main_token)[2]);
    if (version.len < 3) @panic("Version length too short");
    return try b.allocator.dupe(u8, version[1 .. version.len - 1]);
}

fn prebuild(b: *std.Build, step: *std.Build.Step) !void {
    const compile = b.step("prebuild_compile", "Compile static luau");
    const compress = b.step("prebuild_compress", "Compress static files");

    const build_native_target: std.Build.ResolvedTarget = .{
        .query = try std.Target.Query.parse(.{}),
        .result = builtin.target,
    };

    { // Pre-compile Luau
        const dep_luau = b.dependency("luau", .{ .target = build_native_target, .optimize = .Debug });
        const bytecode_builder = b.addExecutable(.{
            .name = "bytecode_builder",
            .root_source_file = b.path("prebuild/bytecode.zig"),
            .target = build_native_target,
            .optimize = .Debug,
        });

        bytecode_builder.root_module.addImport("luau", dep_luau.module("zig-luau"));

        const testing_framework_run = compileFile(
            b,
            bytecode_builder,
            "src/core/lua/testing_lib.luau",
            "src/core/lua/testing_lib.luac",
        );

        compile.dependOn(&testing_framework_run.step);
    }

    { // Compress files
        const embedded_compressor = b.addExecutable(.{
            .name = "embedded_compressor",
            .root_source_file = b.path("prebuild/compressor.zig"),
            .target = build_native_target,
            .optimize = .Debug,
        });

        try compressRecursive(b, embedded_compressor, compress, compile, "src/types/");

        const run = compressFile(
            b,
            embedded_compressor,
            "src/core/lua/testing_lib.luac",
            "src/core/lua/testing_lib.luac.gz",
        );
        run.step.dependOn(compile);
        compress.dependOn(&run.step);
    }

    step.dependOn(compile);
    step.dependOn(compress);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_json = b.dependency("json", .{ .target = target, .optimize = optimize });
    const dep_yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const dep_luau = b.dependency("luau", .{ .target = target, .optimize = optimize });
    const dep_lz4 = b.dependency("lz4", .{ .target = target, .optimize = optimize });
    const dep_czrex = b.dependency("czrex", .{ .target = target, .optimize = optimize });
    const dep_datetime = b.dependency("datetime", .{ .target = target, .optimize = optimize });
    const dep_toml = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const dep_ffi = b.dependency("ffi", .{ .target = target, .optimize = optimize, .safe_build = true });
    const dep_sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
        .SQLITE_ENABLE_RTREE = true,
        .SQLITE_ENABLE_FTS3 = true,
        .SQLITE_ENABLE_FTS5 = true,
        .SQLITE_ENABLE_COLUMN_METADATA = true,
        .SQLITE_MAX_VARIABLE_NUMBER = 200000,
        .SQLITE_ENABLE_MATH_FUNCTIONS = true,
        .SQLITE_ENABLE_FTS3_PARENTHESIS = true,
    });

    const prebuild_step = b.step("prebuild", "Setup project for build");

    try prebuild(b, prebuild_step);

    const version = try getPackageVersion(b);

    const zune_info = b.addOptions();
    zune_info.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "zune",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(prebuild_step);

    exe.root_module.addOptions("zune-info", zune_info);

    exe.root_module.addImport("yaml", dep_yaml.module("yaml"));
    exe.root_module.addImport("lz4", dep_lz4.module("zig-lz4"));
    exe.root_module.addImport("json", dep_json.module("zig-json"));
    exe.root_module.addImport("luau", dep_luau.module("zig-luau"));
    exe.root_module.addImport("regex", dep_czrex.module("czrex"));
    exe.root_module.addImport("datetime", dep_datetime.module("zdt"));
    exe.root_module.addImport("toml", dep_toml.module("tomlz"));
    exe.root_module.addImport("ffi", dep_ffi.module("ffi"));
    exe.root_module.addImport("sqlite", dep_sqlite.module("z-sqlite"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const sample_dylib = b.addSharedLibrary(.{
        .name = "sample",
        .root_source_file = b.path("test/standard/ffi/sample.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    sample_dylib.step.dependOn(prebuild_step);

    const sample_dylib_path = try std.fs.path.resolve(b.allocator, &[_][]const u8{ "../test/standard/ffi/zig-out/", sample_dylib.out_lib_filename });
    defer b.allocator.free(sample_dylib_path);

    const install_sample_dylib = b.addInstallArtifact(sample_dylib, .{});
    const install_test_sample_dylib = b.addInstallFile(install_sample_dylib.artifact.getEmittedBin(), sample_dylib_path);
    install_test_sample_dylib.step.dependOn(&install_sample_dylib.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filters = b.args orelse &.{},
        .test_runner = b.path("test/runner.zig"),
    });

    exe_unit_tests.step.dependOn(prebuild_step);

    exe_unit_tests.root_module.addOptions("zune-info", zune_info);

    exe_unit_tests.root_module.addImport("zune-test-files", b.addModule("test-files", .{
        .root_source_file = b.path("test/files.zig"),
    }));

    exe_unit_tests.root_module.addImport("yaml", dep_yaml.module("yaml"));
    exe_unit_tests.root_module.addImport("lz4", dep_lz4.module("zig-lz4"));
    exe_unit_tests.root_module.addImport("json", dep_json.module("zig-json"));
    exe_unit_tests.root_module.addImport("luau", dep_luau.module("zig-luau"));
    exe_unit_tests.root_module.addImport("regex", dep_czrex.module("czrex"));
    exe_unit_tests.root_module.addImport("datetime", dep_datetime.module("zdt"));
    exe_unit_tests.root_module.addImport("toml", dep_toml.module("tomlz"));
    exe_unit_tests.root_module.addImport("ffi", dep_ffi.module("ffi"));
    exe_unit_tests.root_module.addImport("sqlite", dep_sqlite.module("z-sqlite"));

    exe_unit_tests.step.dependOn(&install_test_sample_dylib.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const version_step = b.step("version", "Get build version");

    version_step.dependOn(&b.addSystemCommand(&.{ "echo", version }).step);
}
