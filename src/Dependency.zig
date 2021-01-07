const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const Lockfile = @import("Lockfile.zig");
const api = @import("api.zig");

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

/// for testing
fn fromString(str: []const u8) !Self {
    var tree = zzz.ZTree(1, 100){};
    const root = try tree.appendText(str);
    return Self.fromZNode(root);
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
    testing.expectError(error.SuperfluousNode, fromString(
        \\something:
        \\  src:
        \\    pkg:
        \\      name: blarg
        \\      version: ^0.1.0
        \\  foo: something
    ));
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
        .alias = "something",
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
        .alias = "something",
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
        .alias = "something",
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
        .alias = "something",
        .src = .{
            .url = .{
                .str = "https://astrolabe.pm",
                .root = "main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

/// serializes dependency information back into zzz format
pub fn addToZNode(
    self: Self,
    tree: *zzz.ZTree(1, 100),
    parent: *zzz.ZNode,
) !void {
    return error.Todo;
}
