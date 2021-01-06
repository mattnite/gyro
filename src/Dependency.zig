const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const Lockfile = @import("Lockfile.zig");

const Self = @This();
const Allocator = std.mem.Allocator;

name: []const u8,
src: Source,

const Source = union(enum) {
    ziglet: struct {
        repository: []const u8,
        version: version.Range,
    },

    github: struct {
        user: []const u8,
        repo: []const u8,
        ref: []const u8,
        root: []const u8,
    },

    raw: struct {
        url: []const u8,
        root: []const u8,
        //integrity: ?Integrity,
    },
};

fn findLatestMatch(self: Self, lockfile: *Lockfile) ?*const Lockfile.Entry {
    var ret: ?*const Lockfile.Entry = null;
    for (lockfile.entries.items) |entry| {}

    return ret;
}

fn resolveLatest(self: Self) !Lockfile.Entry {
    return error.Todo;
}

pub fn resolve(self: Self, allocator: *Allocator, lockfile: *Lockfile) !*const Lockfile.Entry {
    return self.findLatestMatch(lockfile) orelse blk: {
        try lockfile.entries.append(try self.resolveLatest());
        break :blk &lockfile.entries.items[lockfile.entries.items.len - 1];
    };
}

/// There are four ways for a dependency to be declared in the project file:
///
/// A package from the default index:
/// ```
/// name: "^0.1.0"
/// ```
///
/// A package from some other index:
/// ```
/// name:
///   src:
///     pkg: <pkg name> # optional
///     version: <version string>
///     repository: <repository>
/// ```
///
/// A github repo:
/// ```
/// name:
///   src:
///     github:
///       user: <user>
///       repo: <repo>
///       ref: <ref>
///   root: <root file> # TODO: what if it has a project.zzz file?
/// ```
///
/// A raw url:
/// ```
/// name:
///   src:
///     url: <url>
///   root: <root file> # TODO: what if it has a project.zzz file?
///   integrity:
///     <type>: <integrity str>
pub fn fromZNode(node: *const zzz.ZNode) !Self {
    // check if only one child node and that it has no children
    return error.Todo;
}

/// serializes dependency information back into zzz format
pub fn addToZNode(self: Self, tree: *zzz.ZTree(1, 100), parent: *zzz.ZNode) !void {
    return error.Todo;
}
