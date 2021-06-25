usingnamespace std.build;
const std = @import("std");
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) !void {
    var target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const repository = b.option([]const u8, "repo", "default package index (default is astrolabe.pm)");

    const gyro = b.addExecutable("gyro", "src/main.zig");
    gyro.setTarget(target);
    gyro.setBuildMode(mode);
    pkgs.addAllTo(gyro);

    gyro.addBuildOption([]const u8, "default_repo", repository orelse "astrolabe.pm");
    gyro.install();

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    pkgs.addAllTo(tests);
    tests.addBuildOption([]const u8, "default_repo", repository orelse "astrolabe.pm");
    tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
