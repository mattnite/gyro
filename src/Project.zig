const std = @import("std");
const zzz = @import("zzz");
const version = @import("version");
const Package = @import("Package.zig");

usingnamespace @import("common.zig");

const Self = @This();

allocator: *std.mem.Allocator,
text: []const u8,
packages: std.StringHashMap(Package),

pub const Iterator = struct {
    inner: std.StringHashMap(Package).Iterator,

    pub fn next(self: *Iterator) ?*Package {
        return if (self.inner.next()) |entry| &entry.value else null;
    }
};

pub fn init(allocator: *std.mem.Allocator, file: std.fs.File) !Self {
    return Self{
        .allocator = allocator,
        .text = try file.readToEndAlloc(allocator, std.math.maxInt(usize)),
        .packages = std.StringHashMap(Package).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.packages.iterator();
    while (it.next()) |entry| {
        entry.value.deinit();
        self.packages.removeAssertDiscard(entry.key);
    }

    self.packages.deinit();
    self.allocator.free(self.text);
}

pub fn contains(self: Self, name: []const u8) bool {
    return self.packages.contains(name);
}

pub fn get(self: Self, name: []const u8) ?*Package {
    return if (self.packages.getEntry(name)) |entry| &entry.value else null;
}

pub fn iterator(self: Self) Iterator {
    return Iterator{ .inner = self.packages.iterator() };
}

fn fromZNode(node: *const zzz.ZNode) !Self {
    return error.Todo;
}

pub fn fromFile(allocator: *std.mem.Allocator, file: std.fs.File) !Self {
    var ret = try Self.init(allocator, file);
    errdefer ret.deinit();

    if (std.mem.indexOf(u8, ret.text, "\r\n") != null) {
        std.log.err("project.zzz requires LF line endings, not CRLF", .{});
        return error.LineEnding;
    }

    var tree = zzz.ZTree(1, 100){};
    var root = try tree.appendText(ret.text);

    // TODO: some sort of 'apps' or 'compiled' tag
    const libs = zFindChild(root, "libs") orelse {
        std.log.err("no libraries declared", .{});
        return error.NoLibs;
    };

    const opt_deps = zFindChild(root, "deps");
    const opt_build_deps = zFindChild(root, "build_deps");

    var it = ZChildIterator.init(libs);
    while (it.next()) |node| {
        const name = try zGetString(node);

        const ver_str = (try zFindString(node, "version")) orelse {
            std.log.err("missing version string in package", .{});
            return error.NoVersion;
        };

        const ver = version.Semver.parse(ver_str) catch |err| {
            std.log.err("failed to parse version string '{}', must be <major>.<minor>.<patch>: {}", .{ ver_str, err });
            return err;
        };

        const res = try ret.packages.getOrPut(name);
        if (res.found_existing) {
            std.log.err("duplicate exported packages {}", .{name});
            return error.DuplicatePackage;
        }

        res.entry.value = Package.init(allocator, name, ver);
        try res.entry.value.fillFromZNode(node, opt_deps, opt_build_deps);
    }

    return ret;
}
