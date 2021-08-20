const std = @import("std");
const zzz = @import("zzz");
const version = @import("version");
const Package = @import("Package.zig");
const Dependency = @import("Dependency.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

usingnamespace @import("common.zig");

const Self = @This();

allocator: *Allocator,
text: []const u8,
packages: std.StringHashMap(Package),
deps: std.ArrayList(Dependency),
build_deps: std.ArrayList(Dependency),

pub const Iterator = struct {
    inner: std.StringHashMap(Package).Iterator,

    pub fn next(self: *Iterator) ?*Package {
        return if (self.inner.next()) |entry| &entry.value_ptr.* else null;
    }
};

fn init(allocator: *Allocator, file: std.fs.File) !Self {
    return Self{
        .allocator = allocator,
        .text = try file.readToEndAlloc(allocator, std.math.maxInt(usize)),
        .packages = std.StringHashMap(Package).init(allocator),
        .deps = std.ArrayList(Dependency).init(allocator),
        .build_deps = std.ArrayList(Dependency).init(allocator),
    };
}

fn deinit(self: *Self) void {
    var it = self.packages.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
        _ = self.packages.remove(entry.key_ptr.*);
    }

    self.deps.deinit();
    self.build_deps.deinit();
    self.packages.deinit();
    self.allocator.free(self.text);
}

pub fn destroy(self: *Self) void {
    self.deinit();
    self.allocator.destroy(self);
}

pub fn contains(self: Self, name: []const u8) bool {
    return self.packages.contains(name);
}

pub fn get(self: Self, name: []const u8) ?*Package {
    return if (self.packages.getEntry(name)) |entry| &entry.value_ptr.* else null;
}

pub fn iterator(self: Self) Iterator {
    return Iterator{ .inner = self.packages.iterator() };
}

pub fn fromText(allocator: *Allocator, text: []const u8) !*Self {
    var ret = try allocator.create(Self);
    ret.* = Self{
        .allocator = allocator,
        .text = text,
        .packages = std.StringHashMap(Package).init(allocator),
        .deps = std.ArrayList(Dependency).init(allocator),
        .build_deps = std.ArrayList(Dependency).init(allocator),
    };
    errdefer {
        ret.deinit();
        allocator.destroy(ret);
    }

    if (std.mem.indexOf(u8, ret.text, "\r\n") != null) {
        std.log.err("gyro.zzz requires LF line endings, not CRLF", .{});
        return error.Explained;
    }

    var tree = zzz.ZTree(1, 1000){};
    var root = try tree.appendText(ret.text);
    if (zFindChild(root, "pkgs")) |pkgs| {
        var it = ZChildIterator.init(pkgs);
        while (it.next()) |node| {
            const name = try zGetString(node);

            const ver_str = (try zFindString(node, "version")) orelse {
                std.log.err("missing version string in package", .{});
                return error.Explained;
            };

            const ver = version.Semver.parse(allocator, ver_str) catch |err| {
                std.log.err("failed to parse version string '{s}', must be <major>.<minor>.<patch>: {}", .{ ver_str, err });
                return error.Explained;
            };

            const res = try ret.packages.getOrPut(name);
            if (res.found_existing) {
                std.log.err("duplicate exported packages {s}", .{name});
                return error.Explained;
            }

            res.value_ptr.* = try Package.init(
                allocator,
                name,
                ver,
                ret,
            );

            try res.value_ptr.fillFromZNode(node);
        }
    }

    if (zFindChild(root, "deps")) |deps| {
        var it = ZChildIterator.init(deps);
        while (it.next()) |dep_node| {
            const dep = try Dependency.fromZNode(allocator, dep_node);
            for (ret.deps.items) |other| {
                if (std.mem.eql(u8, dep.alias, other.alias)) {
                    std.log.err("'{s}' alias in 'deps' is declared multiple times", .{dep.alias});
                    return error.Explained;
                }
            } else {
                try ret.deps.append(dep);
            }
        }
    }

    if (zFindChild(root, "build_deps")) |build_deps| {
        var it = ZChildIterator.init(build_deps);
        while (it.next()) |dep_node| {
            const dep = try Dependency.fromZNode(allocator, dep_node);
            for (ret.build_deps.items) |other| {
                if (std.mem.eql(u8, dep.alias, other.alias)) {
                    std.log.err("'{s}' alias in 'build_deps' is declared multiple times", .{dep.alias});
                    return error.Explained;
                }
            } else {
                try ret.build_deps.append(dep);
            }
        }
    }

    return ret;
}

pub fn fromFile(allocator: *Allocator, file: std.fs.File) !*Self {
    return fromText(allocator, try file.reader().readAllAlloc(allocator, std.math.maxInt(usize)));
}

pub fn toFile(self: *Self, file: std.fs.File) !void {
    var tree = zzz.ZTree(1, 1000){};
    var root = try tree.addNode(null, .Null);

    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    try file.setEndPos(0);
    try file.seekTo(0);
    if (self.packages.count() > 0) {
        var pkgs = try tree.addNode(root, .{ .String = "pkgs" });
        var it = self.packages.iterator();
        while (it.next()) |entry| _ = try entry.value_ptr.addToZNode(&arena, &tree, pkgs);
    }

    if (self.deps.items.len > 0) {
        var deps = try tree.addNode(root, .{ .String = "deps" });
        for (self.deps.items) |dep| try dep.addToZNode(&arena, &tree, deps, false);
    }

    if (self.build_deps.items.len > 0) {
        var build_deps = try tree.addNode(root, .{ .String = "build_deps" });
        for (self.build_deps.items) |dep| try dep.addToZNode(&arena, &tree, build_deps, false);
    }

    try root.stringifyPretty(file.writer());
}
