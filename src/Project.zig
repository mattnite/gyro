const std = @import("std");
const zzz = @import("zzz");
const version = @import("version");
const Package = @import("Package.zig");
const Dependency = @import("Dependency.zig");

usingnamespace @import("common.zig");

const Self = @This();

allocator: *std.mem.Allocator,
text: []const u8,
packages: std.StringHashMap(Package),
dependencies: std.ArrayList(Dependency),
build_dependencies: std.ArrayList(Dependency),

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
        .dependencies = std.ArrayList(Dependency).init(allocator),
        .build_dependencies = std.ArrayList(Dependency).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.packages.iterator();
    while (it.next()) |entry| {
        entry.value.deinit();
        self.packages.removeAssertDiscard(entry.key);
    }

    self.dependencies.deinit();
    self.build_dependencies.deinit();
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

pub fn fromFile(allocator: *std.mem.Allocator, file: std.fs.File) !Self {
    var ret = try Self.init(allocator, file);
    errdefer ret.deinit();

    if (std.mem.indexOf(u8, ret.text, "\r\n") != null) {
        std.log.err("gyro.zzz requires LF line endings, not CRLF", .{});
        return error.Explained;
    }

    var tree = zzz.ZTree(1, 1000){};
    var root = try tree.appendText(ret.text);

    if (zFindChild(root, "deps")) |deps| {
        var it = ZChildIterator.init(deps);
        while (it.next()) |dep_node| {
            const dep = try Dependency.fromZNode(dep_node);
            for (ret.dependencies.items) |other| {
                if (std.mem.eql(u8, dep.alias, other.alias)) {
                    std.log.err("'{s}' alias in 'deps' is declared multiple times", .{dep.alias});
                    return error.Explained;
                }
            } else {
                try ret.dependencies.append(dep);
            }
        }
    }

    if (zFindChild(root, "build_deps")) |build_deps| {
        var it = ZChildIterator.init(build_deps);
        while (it.next()) |dep_node| {
            const dep = try Dependency.fromZNode(dep_node);
            for (ret.build_dependencies.items) |other| {
                if (std.mem.eql(u8, dep.alias, other.alias)) {
                    std.log.err("'{s}' alias in 'build_deps' is declared multiple times", .{dep.alias});
                    return error.Explained;
                }
            } else {
                try ret.build_dependencies.append(dep);
            }
        }
    }

    if (zFindChild(root, "pkgs")) |pkgs| {
        var it = ZChildIterator.init(pkgs);
        while (it.next()) |node| {
            const name = try zGetString(node);

            const ver_str = (try zFindString(node, "version")) orelse {
                std.log.err("missing version string in package", .{});
                return error.Explained;
            };

            const ver = version.Semver.parse(ver_str) catch |err| {
                std.log.err("failed to parse version string '{s}', must be <major>.<minor>.<patch>: {}", .{ ver_str, err });
                return error.Explained;
            };

            const res = try ret.packages.getOrPut(name);
            if (res.found_existing) {
                std.log.err("duplicate exported packages {s}", .{name});
                return error.Explained;
            }

            res.entry.value = Package.init(
                allocator,
                name,
                ver,
                ret.dependencies.items,
                ret.build_dependencies.items,
            );
            try res.entry.value.fillFromZNode(node);
        }
    }

    return ret;
}
