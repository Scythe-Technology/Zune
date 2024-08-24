const std = @import("std");
const builtin = @import("builtin");

fn compressFile(b: *std.Build, exe: *std.Build.Step.Compile, file: []const u8, out_file: []const u8) *std.Build.Step.Run {
    const embedded_compressor_run = b.addRunArtifact(exe);

    embedded_compressor_run.addArg(b.path(file).getPath(b));
    embedded_compressor_run.addArg(b.path(out_file).getPath(b));

    return embedded_compressor_run;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zig_json = b.dependency("zig-json", .{ .target = target, .optimize = optimize });
    const zig_yaml = b.dependency("zig-yaml", .{ .target = target, .optimize = optimize });
    const zig_luau = b.dependency("zig-luau", .{ .target = target, .optimize = optimize });
    const zig_lz4 = b.dependency("zig-lz4", .{ .target = target, .optimize = optimize });

    const preprocess = b.step("preprocess", "Preprocess the project");
    const build_native_target: std.Build.ResolvedTarget = .{
        .query = try std.Target.Query.parse(.{}),
        .result = builtin.target,
    };
    { // Pre-compile Luau
        const local_zigLuauDep = b.dependency("zig-luau", .{ .target = build_native_target, .optimize = optimize });
        const bytecode_builder = b.addExecutable(.{
            .name = "bytecode_builder",
            .root_source_file = b.path("prebuild/bytecode.zig"),
            .target = build_native_target,
            .optimize = optimize,
        });

        bytecode_builder.root_module.addImport("luau", local_zigLuauDep.module("zig-luau"));

        const bytecode_builder_run = b.addRunArtifact(bytecode_builder);

        bytecode_builder_run.addArg(b.path("src/core/lua/testing_lib.luau").getPath(b));
        bytecode_builder_run.addArg(b.path("src/core/lua/testing_lib.luac").getPath(b));

        preprocess.dependOn(&bytecode_builder_run.step);
    }

    { // Compress files
        const embedded_compressor = b.addExecutable(.{
            .name = "embedded_compressor",
            .root_source_file = b.path("prebuild/compressor.zig"),
            .target = build_native_target,
            .optimize = optimize,
        });

        const dir = try std.fs.cwd().openDir("src/types/core/", .{ .iterate = true });
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and !std.mem.eql(u8, entry.name[entry.name.len - 2 ..], "gz")) {
                const file_name = try std.mem.concat(b.allocator, u8, &[_][]const u8{ "src/types/core/", entry.name });
                defer b.allocator.free(file_name);
                const out_file_name = try std.mem.concat(b.allocator, u8, &[_][]const u8{ "src/types/core/", entry.name, ".gz" });
                defer b.allocator.free(out_file_name);
                preprocess.dependOn(&compressFile(b, embedded_compressor, file_name, out_file_name).step);
            }
        }

        preprocess.dependOn(&compressFile(b, embedded_compressor, "src/core/lua/testing_lib.luac", "src/core/lua/testing_lib.luac.gz").step);
    }

    const exe = b.addExecutable(.{
        .name = "zune",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(preprocess);

    exe.root_module.addImport("yaml", zig_yaml.module("yaml"));
    exe.root_module.addImport("lz4", zig_lz4.module("zig-lz4"));
    exe.root_module.addImport("json", zig_json.module("zig-json"));
    exe.root_module.addImport("luau", zig_luau.module("zig-luau"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.step.dependOn(preprocess);

    exe_unit_tests.root_module.addImport("yaml", zig_yaml.module("yaml"));
    exe_unit_tests.root_module.addImport("lz4", zig_lz4.module("zig-lz4"));
    exe_unit_tests.root_module.addImport("json", zig_json.module("zig-json"));
    exe_unit_tests.root_module.addImport("luau", zig_luau.module("zig-luau"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
