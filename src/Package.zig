const std = @import("std");
const version = @import("version");
const tar = @import("tar");
const glob = @import("glob");
const zzz = @import("zzz");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");

const Self = @This();
const Allocator = std.mem.Allocator;

arena: std.heap.ArenaAllocator,
name: []const u8,
version: version.Semver,
project: *Project,
root: ?[]const u8,
files: std.ArrayList([]const u8),

// meta info
description: ?[]const u8,
license: ?[]const u8,
homepage_url: ?[]const u8,
source_url: ?[]const u8,
tags: std.ArrayList([]const u8),

pub fn init(
    allocator: *Allocator,
    name: []const u8,
    ver: version.Semver,
    project: *Project,
) !Self {
    var ret = Self{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .name = name,
        .version = ver,
        .project = project,
        .files = std.ArrayList([]const u8).init(allocator),
        .tags = std.ArrayList([]const u8).init(allocator),

        .root = null,
        .description = null,
        .license = null,
        .homepage_url = null,
        .source_url = null,
    };

    return ret;
}

pub fn deinit(self: *Self) void {
    self.tags.deinit();
    self.files.deinit();
    self.arena.deinit();
}

pub fn fillFromZNode(
    self: *Self,
    node: *zzz.ZNode,
) !void {
    if (utils.zFindChild(node, "files")) |files| {
        var it = utils.ZChildIterator.init(files);
        while (it.next()) |path| try self.files.append(try utils.zGetString(path));
    }

    if (utils.zFindChild(node, "deps") != null) {
        std.log.warn("subdependencies are no longer supported", .{});
    }

    if (utils.zFindChild(node, "tags")) |tags| {
        var it = utils.ZChildIterator.init(tags);
        while (it.next()) |tag| try self.tags.append(try utils.zGetString(tag));
    }

    inline for (std.meta.fields(Self)) |field| {
        if (@TypeOf(@field(self, field.name)) == ?[]const u8) {
            @field(self, field.name) = try utils.zFindString(node, field.name);
        }
    }
}

fn createManifest(self: *Self, tree: *zzz.ZTree(1, 1000)) !void {
    var root = try tree.addNode(null, .Null);
    try utils.zPutKeyString(tree, root, "name", self.name);
    var ver_str = try std.fmt.allocPrint(&self.arena.allocator, "{}", .{self.version});
    try utils.zPutKeyString(tree, root, "version", ver_str);

    inline for (std.meta.fields(Self)) |field| {
        if (@TypeOf(@field(self, field.name)) == ?[]const u8) {
            if (@field(self, field.name)) |value| {
                try utils.zPutKeyString(tree, root, field.name, value);
            } else if (std.mem.eql(u8, field.name, "root")) {
                try utils.zPutKeyString(tree, root, field.name, "src/main.zig");
            }
        }
    }

    if (self.tags.items.len > 0) {
        var tags = try tree.addNode(root, .{ .String = "tags" });
        for (self.tags.items) |tag| _ = try tree.addNode(tags, .{ .String = tag });
    }

    // TODO: check for collisions between different deps sets
    if (self.project.deps.items.len > 0) {
        var deps = try tree.addNode(root, .{ .String = "deps" });
        for (self.project.deps.items) |dep| try dep.addToZNode(&self.arena, tree, deps, true);
    }

    if (self.project.build_deps.items.len > 0) {
        var build_deps = try tree.addNode(root, .{ .String = "build_deps" });
        for (self.project.build_deps.items) |dep| try dep.addToZNode(&self.arena, tree, build_deps, true);
    }
}

pub fn filename(self: Self, allocator: *Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{}.tar", .{ self.name, self.version });
}

pub fn bundle(self: *Self, root: std.fs.Dir, output_dir: std.fs.Dir) !void {
    const fname = try self.filename(&self.arena.allocator);
    const file = try output_dir.createFile(fname, .{
        .truncate = true,
        .read = true,
    });
    errdefer output_dir.deleteFile(fname) catch {};
    defer file.close();

    var tarball = tar.builder(self.arena.child_allocator, file.writer());
    defer {
        tarball.finish() catch {};
        tarball.deinit();
    }

    var fifo = std.fifo.LinearFifo(u8, .Dynamic).init(self.arena.child_allocator);
    defer fifo.deinit();

    var manifest = zzz.ZTree(1, 1000){};
    try self.createManifest(&manifest);
    try manifest.rootSlice()[0].stringify(fifo.writer());
    try fifo.writer().writeByte('\n');
    try tarball.addSlice(fifo.readableSlice(0), "manifest.zzz");

    if (self.root) |root_file| {
        tarball.addFile(root, "pkg", root_file) catch |err| {
            if (err == error.FileNotFound) {
                std.log.err("{s}'s root is declared as {s}, but it does not exist", .{
                    self.name,
                    root_file,
                });
                return error.Explained;
            } else return err;
        };
    } else {
        tarball.addFile(root, "pkg", "src/main.zig") catch |err| {
            if (err == error.FileNotFound) {
                std.log.err("there's no src/main.zig, did you forget to declare a {s}'s root file in gyro.zzz?", .{
                    self.name,
                });
                return error.Explained;
            } else return err;
        };
    }

    for (self.files.items) |pattern| {
        var dir = try root.openDir(".", .{ .iterate = true, .access_sub_paths = true });
        defer dir.close();

        var it = try glob.Iterator.init(self.arena.child_allocator, dir, pattern);
        defer it.deinit();

        while (try it.next()) |subpath| {
            tarball.addFile(dir, "pkg", subpath) catch |err| {
                return if (err == error.FileNotFound) blk: {
                    std.log.err("file pattern '{s}' wants path '{s}', but it doesn't exist", .{
                        pattern,
                        subpath,
                    });
                    break :blk error.Explained;
                } else err;
            };
        }
    }
}

pub fn addToZNode(
    self: Self,
    arena: *std.heap.ArenaAllocator,
    tree: *zzz.ZTree(1, 1000),
    parent: *zzz.ZNode,
) !void {
    var node = try tree.addNode(parent, .{ .String = self.name });
    var ver_str = try std.fmt.allocPrint(&arena.allocator, "{}", .{self.version});
    try utils.zPutKeyString(tree, node, "version", ver_str);

    inline for (std.meta.fields(Self)) |field| {
        if (@TypeOf(@field(self, field.name)) == ?[]const u8) {
            if (@field(self, field.name)) |value| {
                try utils.zPutKeyString(tree, node, field.name, value);
            } else if (std.mem.eql(u8, field.name, "node")) {
                try utils.zPutKeyString(tree, node, field.name, "src/main.zig");
            }
        }
    }

    if (self.tags.items.len > 0) {
        var tags = try tree.addNode(node, .{ .String = "tags" });
        for (self.tags.items) |tag| _ = try tree.addNode(tags, .{ .String = tag });
    }
}
