const std = @import("std");
const zzz = @import("zzz");
const version = @import("version");
const Package = @import("Package.zig");
const Dependency = @import("Dependency.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Self = @This();

allocator: *Allocator,
base_dir: []const u8,
text: []const u8,
owns_text: bool,
packages: std.StringHashMap(Package),
deps: std.ArrayList(Dependency),
build_deps: std.ArrayList(Dependency),

pub const Iterator = struct {
    inner: std.StringHashMapUnmanaged(Package).Iterator,

    pub fn next(self: *Iterator) ?*Package {
        return if (self.inner.next()) |entry| &entry.value_ptr.* else null;
    }
};

fn create(
    allocator: *Allocator,
    base_dir: []const u8,
    text: []const u8,
    owns_text: bool,
) !*Self {
    const ret = try allocator.create(Self);
    errdefer allocator.destroy(ret);

    ret.* = Self{
        .allocator = allocator,
        .base_dir = base_dir,
        .text = text,
        .owns_text = owns_text,
        .packages = std.StringHashMap(Package).init(allocator),
        .deps = std.ArrayList(Dependency).init(allocator),
        .build_deps = std.ArrayList(Dependency).init(allocator),
    };
    errdefer ret.deinit();

    if (std.mem.indexOf(u8, ret.text, "\r\n") != null) {
        std.log.err("gyro.zzz requires LF line endings, not CRLF", .{});
        return error.Explained;
    }

    var tree = zzz.ZTree(1, 1000){};
    var root = try tree.appendText(ret.text);
    if (utils.zFindChild(root, "pkgs")) |pkgs| {
        var it = utils.ZChildIterator.init(pkgs);
        while (it.next()) |node| {
            const name = try utils.zGetString(node);

            const ver_str = (try utils.zFindString(node, "version")) orelse {
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

    if (utils.zFindChild(root, "deps")) |deps| {
        var it = utils.ZChildIterator.init(deps);
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

    if (utils.zFindChild(root, "build_deps")) |build_deps| {
        var it = utils.ZChildIterator.init(build_deps);
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

fn deinit(self: *Self) void {
    std.log.debug("deiniting project for {s}", .{self.base_dir});
    var it = self.packages.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
        _ = self.packages.remove(entry.key_ptr.*);
    }

    self.deps.deinit();
    self.build_deps.deinit();
    self.packages.deinit();
    if (self.owns_text)
        self.allocator.free(self.text);
}

pub fn destroy(self: *Self) void {
    self.deinit();
    self.allocator.destroy(self);
}

pub fn fromUnownedText(allocator: *Allocator, base_dir: []const u8, text: []const u8) !*Self {
    return try Self.create(allocator, base_dir, text, false);
}

pub fn fromFile(allocator: *Allocator, base_dir: []const u8, file: std.fs.File) !*Self {
    return Self.create(
        allocator,
        base_dir,
        try file.reader().readAllAlloc(allocator, std.math.maxInt(usize)),
        true,
    );
}

pub fn fromDirPath(
    allocator: *Allocator,
    base_dir: []const u8,
) !*Self {
    var dir = try std.fs.cwd().openDir(base_dir, .{});
    defer dir.close();

    const file = try dir.openFile("gyro.zzz", .{});
    defer file.close();

    return Self.fromFile(allocator, base_dir, file);
}

pub fn write(self: Self, writer: anytype) !void {
    var tree = zzz.ZTree(1, 1000){};
    var root = try tree.addNode(null, .Null);

    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();

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

    try root.stringifyPretty(writer);
}

pub fn toFile(self: *Self, file: std.fs.File) !void {
    try file.setEndPos(0);
    try file.seekTo(0);
    try self.write(file.writer());
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
