const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const api = @import("api.zig");
const Dependency = @import("Dependency.zig");
const DependencyTree = @import("DependencyTree.zig");
usingnamespace @import("common.zig");

const Self = @This();
const Allocator = std.mem.Allocator;

allocator: *Allocator,
text: []const u8,
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

    pub fn fromLine(line: []const u8) !Entry {
        var it = std.mem.tokenize(line, " \t");
        const first = it.next() orelse return error.EmptyLine;

        return if (std.mem.eql(u8, first, "url"))
            Entry{
                .url = .{
                    .root = it.next() orelse return error.NoRoot,
                    .str = it.next() orelse return error.NoUrl,
                },
            }
        else if (std.mem.eql(u8, first, "github"))
            Entry{
                .github = .{
                    .user = it.next() orelse return error.NoUser,
                    .repo = it.next() orelse return error.NoRepo,
                    .root = it.next() orelse return error.NoRoot,
                    .commit = it.next() orelse return error.NoCommit,
                },
            }
        else blk: {
            const repo = if (std.mem.eql(u8, first, "default")) api.default_repo else first;
            break :blk Entry{
                .pkg = .{
                    .repository = repo,
                    .name = it.next() orelse return error.NoName,
                    .version = try version.Semver.parse(it.next() orelse return error.NoVersion),
                },
            };
        };
    }

    pub fn packagePath(self: Entry, allocator: *Allocator) ![]const u8 {
        return error.Todo;
    }

    pub fn getDeps(self: Entry, tree: *DependencyTree) !std.ArrayList(Dependency) {
        switch (self) {
            .pkg => |pkg| {
                const text = try api.getDependencies(
                    tree.allocator,
                    pkg.repository,
                    pkg.name,
                    pkg.version,
                );
                errdefer tree.allocator.free(text);

                var ret = std.ArrayList(Dependency).init(tree.allocator);
                errdefer ret.deinit();

                var ztree = zzz.ZTree(1, 100){};
                var root = try ztree.appendText(text);
                var it = ZChildIterator.init(root);
                while (it.next()) |node| try ret.append(try Dependency.fromZNode(node));

                try tree.buf_pool.append(tree.allocator, text);

                return ret;
            },
            .github => |gh| {
                // fetch tarball
                // read gyro.zzz and deserialize deps
                return error.Todo;
            },
            .url => |url| {
                // fetch tarball
                // read gyro.zzz and deserialize deps
                return error.Todo;
            },
        }
    }

    pub fn fetch(self: Entry) !void {
        switch (self) {
            .pkg => |pkg| {},
            .github => |gh| {},
            .url => |url| {},
        }

        return error.Todo;
    }

    pub fn write(self: Self, writer: anytype) !void {
        switch (self) {
            .pkg => |pkg| {
                const repo = if (std.mem.eql(u8, pkg.repository, api.default_repo))
                    "default"
                else
                    pkg.repository;

                try writer.print("{s} {s} {}.{}.{}", .{
                    repo,
                    pkg.name,
                    pkg.version.major,
                    pkg.verion.minor,
                    pkg.verion.patch,
                });
            },
            .github => |gh| try writer.print("github {s} {s} {s} {s}", .{
                gh.user,
                gh.repo,
                gh.root,
                gh.commit,
            }),
            .url => |url| try writer.print("url {s} {s}", .{ url.root, url.str }),
        }

        try writer.writeByte('\n');
    }
};

pub fn fromFile(allocator: *Allocator, file: std.fs.File) !Self {
    var ret = Self{
        .allocator = allocator,
        .entries = std.ArrayList(Entry).init(allocator),
        .text = try file.readToEndAlloc(allocator, std.math.maxInt(usize)),
    };

    var it = std.mem.tokenize(ret.text, "\n");
    while (it.next()) |line| try ret.entries.append(try Entry.fromLine(line));

    return ret;
}

pub fn deinit(self: *Self) void {
    self.entries.deinit();
    self.allocator.free(self.text);
}

pub fn save(self: Self, file: std.fs.File) !void {
    try file.setEndPos(0);
    for (self.entries.items) |entry| try file.writer().print("{}\n", .{entry});
}

pub fn fetchAll(self: Self) !void {
    for (self.entries.items) |entry| {
        try entry.fetch();
    }
}
