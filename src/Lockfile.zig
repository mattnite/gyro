const std = @import("std");
const version = @import("version");
const Dependency = @import("Dependency.zig");

const Self = @This();
const Allocator = std.mem.Allocator;

entries: std.ArrayList(Entry),

pub const Entry = union(enum) {
    pkg: struct {
        name: []const u8,
        version: version.Semver,
        repository: []const u8,
    },
    github: struct {
        user: []const u8,
        repo: []const u8,
        commit: []const u8,
        root: []const u8,
    },
    url: struct {
        str: []const u8,
        root: []const u8,
    },

    pub fn getDeps(self: Entry, allocator: *Allocator) !std.ArrayList(Dependency) {
        return error.Todo;
    }

    pub fn fetch(self: Entry) !void {
        return error.Todo;
    }
};

pub fn fromFile(allocator: *Allocator, file: std.fs.File) !Self {
    return error.Todo;
}

pub fn deinit(self: *Self) void {
    self.entries.deinit();
}

pub fn fetchAll(self: Self) !void {
    for (self.entries.items) |entry| {
        try entry.fetch();
    }
}
