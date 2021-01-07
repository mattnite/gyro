usingnamespace std.build;
const std = @import("std");
const ssl = @import(pkgs.ssl.path);

const clap = .{
    .name = "clap",
    .path = "../zig-clap/clap.zig",
};

const version = .{
    .name = "version",
    .path = "../version/src/main.zig",
    .dependencies = &[_]Pkg{
        .{
            .name = "mecha",
            .path = "../mecha/mecha.zig",
        },
    },
};

const tar = .{
    .name = "tar",
    .path = "../tar/src/main.zig",
};

const zzz = .{
    .name = "zzz",
    .path = "../zzz/src/main.zig",
};

const glob = .{
    .name = "glob",
    .path = "../glob/src/main.zig",
};

fn addAllPkgs(lib: *LibExeObjStep) void {
    lib.addPackage(clap);
    lib.addPackage(version);
    lib.addPackage(tar);
    lib.addPackage(zzz);
    lib.addPackage(glob);
}
pub fn build(b: *Builder) !void {
    var target = b.standardTargetOptions(.{});
    if (target.abi == null) {
        target.abi = switch (std.builtin.os.tag) {
            .windows => .gnu,
            else => .musl,
        };
    }

    const mode = b.standardReleaseOptions();

    const gyro = b.addExecutable("gyro", "src/main.zig");
    gyro.setTarget(target);
    gyro.setBuildMode(mode);
    addAllPkgs(gyro);
    gyro.install();

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    addAllPkgs(tests);
    tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
