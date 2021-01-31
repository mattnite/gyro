const std = @import("std");
const build = std.build;

pub fn addAllTo(artifact: *build.LibExeObjStep) void {
    for (packages) |pkg| {
        artifact.addPackage(pkg);
    }
}

pub const pkgs = struct {};

pub const packages = &[_]build.Pkg{};
