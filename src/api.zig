const std = @import("std");
const version = @import("version");

pub const default_repo = "astrolabe.pm";

pub fn getLatest(
    allocator: *std.mem.Allocator,
    repository: []const u8,
    package: []const u8,
    range: version.Range,
) !version.Semver {
    return error.Todo;
}

pub fn getHeadCommit(
    allocator: *std.mem.Allocator,
    user: []const u8,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    return error.Todo;
}

pub fn getDependencies(
    allocator: *std.mem.Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
) ![]const u8 {
    return error.Todo;
}
