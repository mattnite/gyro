const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const Lockfile = @import("Lockfile.zig");
const DependencyTree = @import("DependencyTree.zig");
const api = @import("api.zig");
usingnamespace @import("common.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const mem = std.mem;
const testing = std.testing;
const SourceType = @TagType(Lockfile.Entry);

alias: []const u8,
src: Source,

const Source = union(SourceType) {
    pkg: struct {
        name: []const u8,
        version: version.Range,
        repository: []const u8,
    },

    github: struct {
        user: []const u8,
        repo: []const u8,
        ref: []const u8,
        root: []const u8,
    },

    url: struct {
        str: []const u8,
        root: []const u8,
        //integrity: ?Integrity,
    },
};

fn findLatestMatch(self: Self, lockfile: *Lockfile) ?*const Lockfile.Entry {
    var ret: ?*const Lockfile.Entry = null;
    for (lockfile.entries.items) |*entry| {
        if (@as(SourceType, self.src) != @as(SourceType, entry.*)) continue;

        switch (self.src) {
            .pkg => |pkg| {
                if (!mem.eql(u8, pkg.name, entry.pkg.name) or
                    !mem.eql(u8, pkg.repository, entry.pkg.repository)) continue;

                const range = pkg.version;
                if (range.contains(entry.pkg.version)) {
                    if (ret != null and entry.pkg.version.cmp(ret.?.pkg.version) != .gt) {
                        continue;
                    }

                    ret = entry;
                }
            },
            // TODO: probably not fix this idunno
            .github => |gh| if (mem.eql(u8, gh.user, entry.github.user) and
                mem.eql(u8, gh.repo, entry.github.user)) return entry,
            .url => |url| if (mem.eql(u8, url.str, entry.url.str)) return entry,
        }
    }

    return ret;
}

fn getLocation(self: Self, tree: *DependencyTree) ![]const u8 {
    return error.Todo;
}

fn resolveLatest(self: Self, tree: *DependencyTree, lockfile: *Lockfile) !Lockfile.Entry {
    return switch (self.src) {
        .pkg => |pkg| .{
            .pkg = .{
                .name = pkg.name,
                .repository = pkg.repository,
                .version = try api.getLatest(
                    tree.allocator,
                    pkg.repository,
                    pkg.name,
                    pkg.version,
                ),
            },
        },
        .github => |gh| blk: {
            const commit = try api.getHeadCommit(tree.allocator, gh.user, gh.repo, gh.ref);
            errdefer tree.allocator.free(commit);

            const location = try self.getLocation(tree);
            errdefer tree.allocator.free(location);

            try tree.buf_pool.append(tree.allocator, commit);
            errdefer _ = tree.buf_pool.pop();

            var entry = Lockfile.Entry{
                .github = .{
                    .user = gh.user,
                    .repo = gh.repo,
                    .commit = commit,
                    .root = gh.root,
                    .locations = std.ArrayListUnmanaged([]const u8){},
                },
            };

            try entry.github.locations.append(lockfile.allocator, location);
            break :blk entry;
        },
        .url => |url| .{
            .url = .{
                .str = url.str,
                .root = url.root,
            },
        },
    };
}

pub fn resolve(self: Self, tree: *DependencyTree, lockfile: *Lockfile) !*const Lockfile.Entry {
    return self.findLatestMatch(lockfile) orelse blk: {
        try lockfile.entries.append(try self.resolveLatest(tree, lockfile));
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
///     pkg:
///       name: <name> # optional
///       version: <version string>
///       repository: <repository> # optional
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
///   root: <root file>
/// ```
///
/// A raw url:
/// ```
/// name:
///   src:
///     url: <url>
///   root: <root file>
///   integrity:
///     <type>: <integrity str>
/// ```
pub fn fromZNode(node: *const zzz.ZNode) !Self {
    if (node.*.child == null) return error.NoChildren;

    const alias = try zGetString(node);

    // check if only one child node and that it has no children
    if (node.*.child.?.value == .String and node.*.child.?.child == null) {
        if (node.*.child.?.sibling != null) return error.Unknown;

        return Self{
            .alias = alias,
            .src = .{
                .pkg = .{
                    .name = alias,
                    .version = try version.Range.parse(try zGetString(node.*.child.?)),
                    .repository = api.default_repo,
                },
            },
        };
    }

    // search for src node
    const src_node = blk: {
        var it = ZChildIterator.init(node);

        while (it.next()) |child| {
            switch (child.value) {
                .String => |str| if (mem.eql(u8, str, "src")) break :blk child,
                else => continue,
            }
        } else return error.SrcTagNotFound;
    };

    const src: Source = blk: {
        const child = src_node.child orelse return error.SrcNeedsChild;
        const src_str = try zGetString(child);
        const src_type = inline for (std.meta.fields(SourceType)) |field| {
            if (mem.eql(u8, src_str, field.name)) break @field(SourceType, field.name);
        } else return error.InvalidSrcTag;

        break :blk switch (src_type) {
            .pkg => .{
                .pkg = .{
                    .name = (try zFindString(child, "name")) orelse alias,
                    .version = try version.Range.parse((try zFindString(child, "version")) orelse return error.MissingVersion),
                    .repository = (try zFindString(child, "repository")) orelse api.default_repo,
                },
            },
            .github => .{
                .github = .{
                    .user = (try zFindString(child, "user")) orelse return error.GithubMissingUser,
                    .repo = (try zFindString(child, "repo")) orelse return error.GithubMissingRepo,
                    .ref = (try zFindString(child, "ref")) orelse return error.GithubMissingRef,
                    .root = (try zFindString(node, "root")) orelse "src/main.zig",
                },
            },
            .url => .{
                .url = .{
                    .str = try zGetString(child.child orelse return error.UrlMissingStr),
                    .root = (try zFindString(node, "root")) orelse "src/main.zig",
                },
            },
        };
    };

    // TODO: integrity

    return Self{ .alias = alias, .src = src };
}

/// for testing
fn fromString(str: []const u8) !Self {
    var tree = zzz.ZTree(1, 100){};
    const root = try tree.appendText(str);
    return Self.fromZNode(root.*.child.?);
}

fn expectDepEqual(expected: Self, actual: Self) void {
    testing.expectEqualStrings(expected.alias, actual.alias);
    testing.expectEqual(@as(SourceType, expected.src), @as(SourceType, actual.src));

    return switch (expected.src) {
        .pkg => |pkg| {
            testing.expectEqualStrings(pkg.name, actual.src.pkg.name);
            testing.expectEqualStrings(pkg.repository, actual.src.pkg.repository);
            testing.expectEqual(pkg.version, actual.src.pkg.version);
        },
        .github => |gh| {
            testing.expectEqualStrings(gh.user, actual.src.github.user);
            testing.expectEqualStrings(gh.repo, actual.src.github.repo);
            testing.expectEqualStrings(gh.ref, actual.src.github.ref);
            testing.expectEqualStrings(gh.root, actual.src.github.root);
        },
        .url => |url| {
            testing.expectEqualStrings(url.str, actual.src.url.str);
            testing.expectEqualStrings(url.root, actual.src.url.root);
        },
    };
}

test "default repo pkg" {
    const actual = try fromString("something: ^0.1.0");
    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .name = "something",
                .version = try version.Range.parse("^0.1.0"),
                .repository = api.default_repo,
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "aliased, default repo pkg" {
    const actual = try fromString(
        \\something:
        \\  src:
        \\    pkg:
        \\      name: blarg
        \\      version: ^0.1.0
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .name = "blarg",
                .version = try version.Range.parse("^0.1.0"),
                .repository = api.default_repo,
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "error if pkg has any other keys" {
    // TODO
    //testing.expectError(error.SuperfluousNode, fromString(
    //    \\something:
    //    \\  src:
    //    \\    pkg:
    //    \\      name: blarg
    //    \\      version: ^0.1.0
    //    \\  foo: something
    //));
}

test "non-default repo pkg" {
    const actual = try fromString(
        \\something:
        \\  src:
        \\    pkg:
        \\      version: ^0.1.0
        \\      repository: example.com
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .name = "something",
                .version = try version.Range.parse("^0.1.0"),
                .repository = "example.com",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "aliased, non-default repo pkg" {
    const actual = try fromString(
        \\something:
        \\  src:
        \\    pkg:
        \\      name: real_name
        \\      version: ^0.1.0
        \\      repository: example.com
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .name = "real_name",
                .version = try version.Range.parse("^0.1.0"),
                .repository = "example.com",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "github default root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: something
        \\      ref: main
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .github = .{
                .user = "test",
                .repo = "something",
                .ref = "main",
                .root = "src/main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "github explicit root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: something
        \\      ref: main
        \\  root: main.zig
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .github = .{
                .user = "test",
                .repo = "something",
                .ref = "main",
                .root = "main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "raw default root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    url: "https://astrolabe.pm"
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .url = .{
                .str = "https://astrolabe.pm",
                .root = "src/main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "raw explicit root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    url: "https://astrolabe.pm"
        \\  root: main.zig
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .url = .{
                .str = "https://astrolabe.pm",
                .root = "main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "pkg can't take a root" {
    // TODO
}

test "pkg can't take an integrity" {
    // TODO
}

test "github can't take an integrity " {
    // TODO
}

/// serializes dependency information back into zzz format
pub fn addToZNode(
    self: Self,
    tree: *zzz.ZTree(1, 100),
    parent: *zzz.ZNode,
) !void {
    return error.Todo;
}
