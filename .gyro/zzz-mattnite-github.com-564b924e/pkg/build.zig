const std = @import("std");
const Builder = std.build.Builder;

pub fn createPackage(comptime root: []const u8) std.build.Pkg {
    return std.build.Pkg{
        .name = "zzz",
        .path = root ++ "/src/main.zig",
        .dependencies = &[_]std.build.Pkg{},
    };
}

const pkgs = struct {
    const zzz = std.build.Pkg{
        .name = "zzz",
        .path = .{ .path = "src/main.zig" },
        .dependencies = &[_]std.build.Pkg{},
    };
};

const Example = struct {
    name: []const u8,
    path: []const u8,
};

const examples = [_]Example{
    Example{
        .name = "building-tree",
        .path = "examples/building_tree.zig",
    },
    Example{
        .name = "loading-particles",
        .path = "examples/loading_particles.zig",
    },
    Example{
        .name = "static-imprint",
        .path = "examples/static_imprint.zig",
    },
    Example{
        .name = "static-tree",
        .path = "examples/static_tree.zig",
    },
};

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{
        .default_target = if (std.builtin.os.tag == .windows)
            std.zig.CrossTarget.parse(.{ .arch_os_abi = "native-native-gnu" }) catch unreachable
        else if (std.builtin.os.tag == .linux)
            std.zig.CrossTarget.fromTarget(.{
                .cpu = std.builtin.cpu,
                .os = std.builtin.os,
                .abi = .musl,
            })
        else
            std.zig.CrossTarget{},
    });

    const examples_step = b.step("examples", "Compiles all examples");
    inline for (examples) |example| {
        const example_exe = b.addExecutable(example.name, example.path);
        example_exe.setOutputDir("bin");
        example_exe.setBuildMode(mode);
        example_exe.setTarget(target);
        example_exe.addPackage(pkgs.zzz);

        examples_step.dependOn(&b.addInstallArtifact(example_exe).step);
    }

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run test suite");
    test_step.dependOn(&main_tests.step);
}
