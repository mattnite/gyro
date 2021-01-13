const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const api = @import("api.zig");
const Dependency = @import("Dependency.zig");
const DependencyTree = @import("DependencyTree.zig");
usingnamespace @import("common.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const Hasher = std.crypto.hash.blake2.Blake2b128;
const testing = std.testing;
const file_proto = "file://";

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
        ref: []const u8,
        commit: []const u8,
        root: []const u8,
    },
    url: struct {
        str: []const u8,
        root: []const u8,
    },

    pub fn fromLine(line: []const u8) !Entry {
        var it = std.mem.tokenize(line, " ");
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
                    .ref = it.next() orelse return error.NoRef,
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

    pub fn getDeps(self: Entry, tree: *DependencyTree) ![]Dependency {
        return switch (self) {
            .pkg => |pkg| blk: {
                const resp = try api.getDependencies(
                    tree.allocator,
                    pkg.repository,
                    pkg.name,
                    pkg.version,
                );
                errdefer {
                    tree.allocator.free(resp.text);
                    tree.allocator.free(resp.deps);
                }

                try tree.buf_pool.append(tree.allocator, resp.text);
                break :blk resp.deps;
            },
            .url, .github => blk: {
                try self.fetch(tree.allocator);
                const base_path = try self.basePath(tree);
                var base_dir = try std.fs.cwd().openDir(
                    base_path,
                    .{ .access_sub_paths = true },
                );
                defer base_dir.close();

                const file = base_dir.openFile(
                    "gyro.zzz",
                    .{ .read = true },
                ) catch |err| {
                    if (err == error.FileNotFound)
                        break :blk &[_]Dependency{}
                    else
                        return err;
                };
                defer file.close();

                const text = try file.reader().readAllAlloc(
                    tree.allocator,
                    std.math.maxInt(usize),
                );
                errdefer tree.allocator.free(text);

                var deps = std.ArrayListUnmanaged(Dependency){};

                var ztree = zzz.ZTree(1, 100){};
                var root = try ztree.appendText(text);
                if (zFindChild(root, "deps")) |deps_node| {
                    var it = ZChildIterator.init(deps_node);
                    while (it.next()) |node|
                        try deps.append(
                            tree.allocator,
                            try Dependency.fromZNode(node),
                        );
                }

                try tree.buf_pool.append(tree.allocator, text);
                break :blk deps.items;
            },
        };
    }

    fn basePath(self: Entry, tree: *DependencyTree) ![]const u8 {
        return if (self == .url and std.mem.startsWith(u8, self.url.str, file_proto))
            self.url.str[file_proto.len..]
        else blk: {
            const package_path = try self.packagePath(tree.allocator);
            defer tree.allocator.free(package_path);

            const ret = try std.fs.path.join(tree.allocator, &[_][]const u8{
                package_path,
                "pkg",
            });
            errdefer tree.allocator.free(ret);

            try tree.buf_pool.append(tree.allocator, ret);
            break :blk ret;
        };
    }

    pub fn rootPath(self: Entry, tree: *DependencyTree) ![]const u8 {
        const root_path = switch (self) {
            .pkg => |pkg| blk: {
                const resp = try api.getRoot(
                    tree.allocator,
                    pkg.repository,
                    pkg.name,
                    pkg.version,
                );
                errdefer tree.allocator.free(resp);

                try tree.buf_pool.append(tree.allocator, resp);
                break :blk resp;
            },
            .github => |gh| gh.root,
            .url => |url| if (std.mem.startsWith(u8, url.str, file_proto)) {
                const ret = try std.fs.path.join(tree.allocator, &[_][]const u8{
                    url.str[file_proto.len..],
                    url.root,
                });
                errdefer tree.allocator.free(ret);

                try tree.buf_pool.append(tree.allocator, ret);
                return ret;
            } else url.root,
        };

        const package_path = try self.packagePath(tree.allocator);
        defer tree.allocator.free(package_path);

        const ret = try std.fs.path.join(tree.allocator, &[_][]const u8{
            package_path,
            "pkg",
            root_path,
        });
        errdefer tree.allocator.free(ret);

        try tree.buf_pool.append(tree.allocator, ret);
        return ret;
    }

    pub fn packagePath(self: Entry, allocator: *Allocator) ![]const u8 {
        var tree = zzz.ZTree(1, 100){};
        var root = try tree.addNode(null, .{ .Null = {} });
        var ver_buf: [8]u8 = undefined;

        switch (self) {
            .pkg => |pkg| {
                var ver_stream = std.io.fixedBufferStream(&ver_buf);
                try ver_stream.writer().print("{}", .{pkg.version});

                var node = try tree.addNode(root, .{ .String = "pkg" });
                try zPutKeyString(&tree, node, "name", pkg.name);
                try zPutKeyString(&tree, node, "version", ver_stream.getWritten());
                try zPutKeyString(&tree, node, "repository", pkg.repository);
            },
            .github => |gh| {
                var node = try tree.addNode(root, .{ .String = "github" });
                try zPutKeyString(&tree, node, "user", gh.user);
                try zPutKeyString(&tree, node, "repo", gh.repo);
                try zPutKeyString(&tree, node, "commit", gh.commit);
            },
            .url => |url| {
                try zPutKeyString(&tree, root, "url", url.str);
            },
        }

        var buf: [std.mem.page_size]u8 = undefined;
        var digest: [Hasher.digest_length]u8 = undefined;
        var ret: [Hasher.digest_length * 2]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);

        try root.stringify(stream.writer());
        Hasher.hash(stream.getWritten(), &digest, .{});

        const lookup = "012345678789abcdef";
        for (digest) |val, i| {
            ret[2 * i] = lookup[val >> 4];
            ret[(2 * i) + 1] = lookup[@truncate(u4, val)];
        }

        var fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(allocator);
        defer fifo.deinit();

        switch (self) {
            .pkg => |pkg| try fifo.writer().print("{s}-{}-{s}", .{ pkg.name, pkg.version, &ret }),
            .github => |gh| try fifo.writer().print("{s}-{s}-{s}", .{ gh.repo, gh.user, gh.commit }),
            .url => |url| try fifo.writer().print("{s}", .{&ret}),
        }

        return std.fs.path.join(allocator, &[_][]const u8{
            ".gyro",
            fifo.readableSlice(0),
        });
    }

    pub fn fetch(self: Entry, allocator: *Allocator) !void {
        switch (self) {
            .url => |url| if (std.mem.startsWith(u8, url.str, "file://"))
                return,
            else => {},
        }

        const base_path = try self.packagePath(allocator);
        defer allocator.free(base_path);

        // here: check for ok file and return if it exists
        var base_dir = try std.fs.cwd().makeOpenPath(base_path, .{
            .access_sub_paths = true,
        });
        defer base_dir.close();

        var found = true;
        base_dir.access("ok", .{ .read = true }) catch |err| {
            if (err == error.FileNotFound)
                found = false
            else
                return err;
        };

        if (found) return;
        switch (self) {
            .pkg => |pkg| try api.getPkg(allocator, pkg.repository, pkg.name, pkg.version, base_dir),
            .github => |gh| {
                var pkg_dir = try base_dir.makeOpenPath("pkg", .{ .access_sub_paths = true });
                defer pkg_dir.close();

                try api.getGithubTarGz(allocator, gh.user, gh.repo, gh.commit, pkg_dir);
            },
            .url => |url| {
                var pkg_dir = try base_dir.makeOpenPath("pkg", .{ .access_sub_paths = true });
                defer pkg_dir.close();

                try api.getTarGz(allocator, url.str, pkg_dir);
            },
        }

        const ok = try base_dir.createFile("ok", .{ .read = true });
        defer ok.close();
    }

    pub fn write(self: Entry, writer: anytype) !void {
        switch (self) {
            .pkg => |pkg| {
                const repo = if (std.mem.eql(u8, pkg.repository, api.default_repo))
                    "default"
                else
                    pkg.repository;

                try writer.print("{s} {s} {}", .{ repo, pkg.name, pkg.version });
            },
            .github => |gh| try writer.print("github {s} {s} {s} {s} {s}", .{
                gh.user,
                gh.repo,
                gh.ref,
                gh.root,
                gh.commit,
            }),
            .url => |url| try writer.print("url {s} {s}", .{ url.root, url.str }),
        }

        try writer.writeAll("\n");
    }
};

fn fromReader(allocator: *Allocator, reader: anytype) !Self {
    var ret = Self{
        .allocator = allocator,
        .entries = std.ArrayList(Entry).init(allocator),
        .text = try reader.readAllAlloc(allocator, std.math.maxInt(usize)),
    };

    var it = std.mem.tokenize(ret.text, "\n");
    while (it.next()) |line| try ret.entries.append(try Entry.fromLine(line));

    return ret;
}

pub fn fromFile(allocator: *Allocator, file: std.fs.File) !Self {
    return fromReader(allocator, file.reader());
}

pub fn deinit(self: *Self) void {
    self.entries.deinit();
    self.allocator.free(self.text);
}

pub fn save(self: Self, file: std.fs.File) !void {
    try file.setEndPos(0);
    for (self.entries.items) |entry| try entry.write(file.writer());
}

pub fn fetchAll(self: Self) !void {
    for (self.entries.items) |entry|
        try entry.fetch(self.allocator);
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
            testing.expectEqualStrings(gh.ref, actual.github.ref);
            testing.expectEqualStrings(gh.commit, actual.github.commit);
            testing.expectEqualStrings(gh.root, actual.github.root);
        },
        .url => |url| {
            testing.expectEqualStrings(url.str, actual.url.str);
            testing.expectEqualStrings(url.root, actual.url.root);
        },
    }
}

test "entry from pkg: default repository" {
    const actual = try Entry.fromLine("default something 0.1.0");
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
    const actual = try Entry.fromLine("my_own_repository foo 0.2.0");
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
    var actual = try Entry.fromLine("github my_user my_repo master src/foo.zig 30d004329543603f76bd9d7daca054878a04fdb5");
    var expected = Entry{
        .github = .{
            .user = "my_user",
            .repo = "my_repo",
            .ref = "master",
            .root = "src/foo.zig",
            .commit = "30d004329543603f76bd9d7daca054878a04fdb5",
        },
    };

    expectEntryEqual(expected, actual);
}

test "entry from url" {
    const actual = try Entry.fromLine("url src/foo.zig https://example.com/something.tar.gz");
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
        \\my_repository foo 0.4.5
        \\github my_user my_repo master src/foo.zig 30d004329543603f76bd9d7daca054878a04fdb5
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
                .ref = "master",
                .root = "src/foo.zig",
                .commit = "30d004329543603f76bd9d7daca054878a04fdb5",
            },
        },
        .{
            .url = .{
                .root = "src/foo.zig",
                .str = "https://example.com/something.tar.gz",
            },
        },
    };

    for (expected) |exp, i| {
        expectEntryEqual(exp, actual.entries.items[i]);
    }
}
