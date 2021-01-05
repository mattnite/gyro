const std = @import("std");
const version = @import("std");

entries: std.ArrayList(Entry),

const Entry = union(enum) {
    ziglet: struct {
        repository: []const u8,
        name: []const u8,
        version: version.Semver,
    },
    github: struct {
        name: []const u8,
        repo: []const u8,
        commit: []const u8,
    },
};
