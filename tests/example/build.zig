const std = @import("std");
const Builder = std.build.Builder;
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zag-example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    inline for (std.meta.fields(@TypeOf(pkgs))) |field| {
        exe.addPackage(@field(pkgs, field.name));
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
