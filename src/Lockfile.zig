const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const api = @import("api.zig");
const Dependency = @import("Dependency.zig");
const DependencyTree = @import("DependencyTree.zig");
usingnamespace @import("common.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const testing = std.testing;

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
        locations: std.ArrayListUnmanaged([]const u8),
    },
    url: struct {
        str: []const u8,
        root: []const u8,
    },

    pub fn fromChunk(allocator: *Allocator, chunk: []const u8) !Entry {
        std.log.info("parsing chunk:\n{}\n------------", .{chunk});
        var line_it = std.mem.tokenize(chunk, "\n");
        var line = line_it.next() orelse return error.EmptyLine;
        var it = std.mem.tokenize(line, " ");
        const first = it.next() orelse return error.EmptyLine;

        return if (std.mem.eql(u8, first, "url"))
            Entry{
                .url = .{
                    .root = it.next() orelse return error.NoRoot,
                    .str = it.next() orelse return error.NoUrl,
                },
            }
        else if (std.mem.eql(u8, first, "github")) blk: {
            var entry = Entry{
                .github = .{
                    .user = it.next() orelse return error.NoUser,
                    .repo = it.next() orelse return error.NoRepo,
                    .root = it.next() orelse return error.NoRoot,
                    .commit = it.next() orelse return error.NoCommit,
                    .locations = std.ArrayListUnmanaged([]const u8){},
                },
            };
            errdefer entry.deinit(allocator);

            while (line_it.next()) |l| try entry.github.locations.append(allocator, l);
            break :blk entry;
        } else blk: {
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

    fn deinit(self: *Entry, allocator: *Allocator) void {
        if (self.* == .github) {
            self.github.locations.deinit(allocator);
        }
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

        try writer.writeAll("\n\n");
    }
};

fn fromReader(allocator: *Allocator, reader: anytype) !Self {
    var ret = Self{
        .allocator = allocator,
        .entries = std.ArrayList(Entry).init(allocator),
        .text = try reader.readAllAlloc(allocator, std.math.maxInt(usize)),
    };

    var pos: usize = 0;
    while (std.mem.indexOf(u8, ret.text[pos..], "\n\n")) |i| : (pos += i + 2) {
        try ret.entries.append(try Entry.fromChunk(allocator, ret.text[pos .. pos + i]));
    }

    if (pos > 0) {
        try ret.entries.append(try Entry.fromChunk(allocator, ret.text[pos..]));
    }

    return ret;
}

pub fn fromFile(allocator: *Allocator, file: std.fs.File) !Self {
    return fromReader(allocator, file.reader());
}

pub fn deinit(self: *Self) void {
    for (self.entries.items) |*entry| entry.deinit(self.allocator);
    self.entries.deinit();
    self.allocator.free(self.text);
}

pub fn save(self: Self, file: std.fs.File) !void {
    try file.setEndPos(0);
    for (self.entries.items) |entry| try file.writer().print("{}\n", .{entry});
}

pub fn fetchAll(self: Self) !void {
    for (self.entries.items) |entry|
        try entry.fetch();
}

fn expectEntryEqual(expected: Entry, actual: Entry) void {
    const SourceType = @TagType(Entry);
    testing.expectEqual(@as(SourceType, expected), @as(SourceType, actual));

    switch (expected) {
        .pkg => |pkg| {
            testing.expectEqualStrings(pkg.name, actual.pkg.name);
            testing.expectEqualStrings(pkg.repository, actual.pkg.repository);
            testing.expectEqual(pkg.version, actual.pkg.version);
        },
        .github => |gh| {
            testing.expectEqualStrings(gh.user, actual.github.user);
            testing.expectEqualStrings(gh.repo, actual.github.repo);
            testing.expectEqualStrings(gh.commit, actual.github.commit);
            testing.expectEqualStrings(gh.root, actual.github.root);

            for (gh.locations.items) |loc, i| {
                testing.expectEqualStrings(loc, actual.github.locations.items[i]);
            }
        },
        .url => |url| {
            testing.expectEqualStrings(url.str, actual.url.str);
            testing.expectEqualStrings(url.root, actual.url.root);
        },
    }
}

test "entry from pkg: default repository" {
    const actual = try Entry.fromChunk(testing.allocator, "default something 0.1.0");
    const expected = Entry{
        .pkg = .{
            .name = "something",
            .repository = api.default_repo,
            .version = version.Semver{
                .major = 0,
                .minor = 1,
                .patch = 0,
            },
        },
    };

    expectEntryEqual(expected, actual);
}

test "entry from pkg: non-default repository" {
    const actual = try Entry.fromChunk(testing.allocator, "my_own_repository foo 0.2.0");
    const expected = Entry{
        .pkg = .{
            .name = "foo",
            .repository = "my_own_repository",
            .version = version.Semver{
                .major = 0,
                .minor = 2,
                .patch = 0,
            },
        },
    };

    expectEntryEqual(expected, actual);
}

test "entry from github" {
    var actual = try Entry.fromChunk(testing.allocator,
        \\github my_user my_repo src/foo.zig 30d004329543603f76bd9d7daca054878a04fdb5
        \\this.is.in.the.tree
        \\another.thing.in.the.tree
    );
    defer actual.deinit(std.testing.allocator);

    var expected = Entry{
        .github = .{
            .user = "my_user",
            .repo = "my_repo",
            .root = "src/foo.zig",
            .commit = "30d004329543603f76bd9d7daca054878a04fdb5",
            .locations = std.ArrayListUnmanaged([]const u8){},
        },
    };
    defer expected.deinit(std.testing.allocator);

    try expected.github.locations.append(std.testing.allocator, "this.is.in.the.tree");
    try expected.github.locations.append(std.testing.allocator, "another.thing.in.the.tree");

    expectEntryEqual(expected, actual);
}

test "entry from url" {
    const actual = try Entry.fromChunk(testing.allocator, "url src/foo.zig https://example.com/something.tar.gz");
    const expected = Entry{
        .url = .{
            .root = "src/foo.zig",
            .str = "https://example.com/something.tar.gz",
        },
    };

    expectEntryEqual(expected, actual);
}

test "lockfile with example of all" {
    const text =
        \\default something 0.1.0
        \\
        \\my_repository foo 0.4.5
        \\
        \\github my_user my_repo src/foo.zig 30d004329543603f76bd9d7daca054878a04fdb5
        \\this.is.in.the.tree
        \\another.thing.in.the.tree
        \\
        \\url src/foo.zig https://example.com/something.tar.gz
    ;
    var stream = std.io.fixedBufferStream(text);
    var actual = try Self.fromReader(std.testing.allocator, stream.reader());
    defer actual.deinit();

    var expected = [_]Entry{
        .{
            .pkg = .{
                .name = "something",
                .repository = api.default_repo,
                .version = version.Semver{
                    .major = 0,
                    .minor = 1,
                    .patch = 0,
                },
            },
        },
        .{
            .pkg = .{
                .name = "foo",
                .repository = "my_repository",
                .version = version.Semver{
                    .major = 0,
                    .minor = 4,
                    .patch = 5,
                },
            },
        },
        .{
            .github = .{
                .user = "my_user",
                .repo = "my_repo",
                .root = "src/foo.zig",
                .commit = "30d004329543603f76bd9d7daca054878a04fdb5",
                .locations = std.ArrayListUnmanaged([]const u8){},
            },
        },
        .{
            .url = .{
                .root = "src/foo.zig",
                .str = "https://example.com/something.tar.gz",
            },
        },
    };
    defer for (expected) |*exp| exp.deinit(std.testing.allocator);

    try expected[2].github.locations.append(std.testing.allocator, "this.is.in.the.tree");
    try expected[2].github.locations.append(std.testing.allocator, "another.thing.in.the.tree");

    for (expected) |exp, i| {
        expectEntryEqual(exp, actual.entries.items[i]);
    }
}
