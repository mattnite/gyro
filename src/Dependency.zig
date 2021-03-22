const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const uri = @import("uri");
const Lockfile = @import("Lockfile.zig");
const DependencyTree = @import("DependencyTree.zig");
const api = @import("api.zig");
usingnamespace @import("common.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const mem = std.mem;
const testing = std.testing;
const SourceType = std.meta.Tag(Lockfile.Entry);

alias: []const u8,
src: Source,

const Source = union(SourceType) {
    pkg: struct {
        user: []const u8,
        name: []const u8,
        version: version.Range,
        repository: []const u8,
        ver_str: []const u8,
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

    local: struct {
        path: []const u8,
        root: []const u8,
    }
};

fn findLatestMatch(self: Self, lockfile: *Lockfile) ?*Lockfile.Entry {
    var ret: ?*Lockfile.Entry = null;
    for (lockfile.entries.items) |entry| {
        if (@as(SourceType, self.src) != @as(SourceType, entry.*)) continue;

        switch (self.src) {
            .pkg => |pkg| {
                if (!mem.eql(u8, pkg.name, entry.pkg.name) or
                    !mem.eql(u8, pkg.user, entry.pkg.user) or
                    !mem.eql(u8, pkg.repository, entry.pkg.repository)) continue;

                const range = pkg.version;
                if (range.contains(entry.pkg.version)) {
                    if (ret != null and entry.pkg.version.cmp(ret.?.pkg.version) != .gt) {
                        continue;
                    }

                    ret = entry;
                }
            },
            .github => |gh| if (mem.eql(u8, gh.user, entry.github.user) and
                mem.eql(u8, gh.repo, entry.github.repo) and
                mem.eql(u8, gh.ref, entry.github.ref) and
                mem.eql(u8, gh.root, entry.github.root)) return entry,
            .url => |url| if (mem.eql(u8, url.str, entry.url.str) and
                mem.eql(u8, url.root, entry.url.root)) return entry,
            .local => |local| if (mem.eql(u8, local.path, entry.local.path) and
                mem.eql(u8, local.root, entry.local.root)) return entry,
        }
    }

    return ret;
}

fn resolveLatest(
    self: Self,
    arena: *std.heap.ArenaAllocator,
    lockfile: *Lockfile,
) !*Lockfile.Entry {
    const allocator = &arena.allocator;
    const ret = try allocator.create(Lockfile.Entry);
    ret.* = switch (self.src) {
        .pkg => |pkg| .{
            .pkg = .{
                .user = pkg.user,
                .name = pkg.name,
                .repository = pkg.repository,
                .version = try api.getLatest(
                    allocator,
                    pkg.repository,
                    pkg.user,
                    pkg.name,
                    pkg.version,
                ),
            },
        },
        .github => |gh| Lockfile.Entry{
            .github = .{
                .user = gh.user,
                .repo = gh.repo,
                .ref = gh.ref,
                .commit = try api.getHeadCommit(allocator, gh.user, gh.repo, gh.ref),
                .root = gh.root,
            },
        },
        .url => |url| Lockfile.Entry{
            .url = .{
                .str = url.str,
                .root = url.root,
            },
        },
        .local => |local| Lockfile.Entry{
            .local = .{
                .path = local.path,
                .root = local.root,
            },
        },
    };

    return ret;
}

pub fn resolve(
    self: Self,
    arena: *std.heap.ArenaAllocator,
    lockfile: *Lockfile,
) !*Lockfile.Entry {
    return self.findLatestMatch(lockfile) orelse blk: {
        const entry = try self.resolveLatest(arena, lockfile);
        try lockfile.entries.append(entry);
        break :blk entry;
    };
}

/// There are four ways for a dependency to be declared in the project file:
///
/// A package from some other index:
/// ```
/// name:
///   src:
///     pkg:
///       user: <user>
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
pub fn fromZNode(node: *zzz.ZNode) !Self {
    if (node.*.child == null) return error.NoChildren;

    // check if only one child node and that it has no children
    if (node.*.child.?.value == .String and node.*.child.?.child == null) {
        if (node.*.child.?.sibling != null) return error.Unknown;
        const key = try zGetString(node);

        const info = try parseUserRepo(key);
        const ver_str = try zGetString(node.*.child.?);
        return Self{
            .alias = info.repo,
            .src = .{
                .pkg = .{
                    .user = info.user,
                    .name = info.repo,
                    .ver_str = ver_str,
                    .version = try version.Range.parse(ver_str),
                    .repository = api.default_repo,
                },
            },
        };
    }

    // search for src node
    const alias = try zGetString(node);
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
                    .user = (try zFindString(child, "user")) orelse return error.MissingUser,
                    .name = (try zFindString(child, "name")) orelse alias,
                    .ver_str = (try zFindString(child, "version")) orelse return error.MissingVersion,
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
            .local => .{
                .local = .{
                    .path = try zGetString(child.child orelse return error.UrlMissingStr),
                    .root = (try zFindString(node, "root")) orelse "src/main.zig",
                },
            },
        };
    };

    if (src == .url) {
        _ = uri.parse(src.url.str) catch |err| {
            switch (err) {
                error.InvalidFormat => {
                    std.log.err(
                        "Failed to parse '{s}' as a url ({}), did you forget to wrap your url in double quotes?",
                        .{ src.url.str, err },
                    );
                },
                error.UnexpectedCharacter => {
                    std.log.err(
                        "Failed to parse '{s}' as a url ({}), did you forget 'file://' for defining a local path?",
                        .{ src.url.str, err },
                    );
                },
                else => return err,
            }
            return error.Explained;
        };
    }

    // TODO: integrity

    return Self{ .alias = alias, .src = src };
}

/// for testing
fn fromString(str: []const u8) !Self {
    var tree = zzz.ZTree(1, 1000){};
    const root = try tree.appendText(str);
    return Self.fromZNode(root.*.child.?);
}

fn expectDepEqual(expected: Self, actual: Self) void {
    testing.expectEqualStrings(expected.alias, actual.alias);
    testing.expectEqual(@as(SourceType, expected.src), @as(SourceType, actual.src));

    return switch (expected.src) {
        .pkg => |pkg| {
            testing.expectEqualStrings(pkg.user, actual.src.pkg.user);
            testing.expectEqualStrings(pkg.name, actual.src.pkg.name);
            testing.expectEqualStrings(pkg.repository, actual.src.pkg.repository);
            testing.expectEqualStrings(pkg.ver_str, actual.src.pkg.ver_str);
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
        .local => |local| {
            testing.expectEqualStrings(local.path, actual.src.local.path);
            testing.expectEqualStrings(local.root, actual.src.local.root);
        }
    };
}

test "default repo pkg" {
    expectDepEqual(Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .user = "matt",
                .name = "something",
                .ver_str = "^0.1.0",
                .version = try version.Range.parse("^0.1.0"),
                .repository = api.default_repo,
            },
        },
    }, try fromString("matt/something: ^0.1.0"));
}

test "aliased, default repo pkg" {
    const actual = try fromString(
        \\something:
        \\  src:
        \\    pkg:
        \\      user: matt
        \\      name: blarg
        \\      version: ^0.1.0
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .user = "matt",
                .name = "blarg",
                .ver_str = "^0.1.0",
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
        \\      user: matt
        \\      version: ^0.1.0
        \\      repository: example.com
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .user = "matt",
                .name = "something",
                .ver_str = "^0.1.0",
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
        \\      user: matt
        \\      name: real_name
        \\      version: ^0.1.0
        \\      repository: example.com
    );

    const expected = Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .user = "matt",
                .name = "real_name",
                .ver_str = "^0.1.0",
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

test "local with default root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    local: "mypkgs/cool-project"
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .local = .{
                .path = "mypkgs/cool-project",
                .root = "src/main.zig",
            },
        },
    };

    expectDepEqual(expected, actual);
}

test "local with explicit root" {
    const actual = try fromString(
        \\foo:
        \\  src:
        \\    local: "mypkgs/cool-project"
        \\  root: main.zig
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .local = .{
                .path = "mypkgs/cool-project",
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
    arena: *std.heap.ArenaAllocator,
    tree: *zzz.ZTree(1, 1000),
    parent: *zzz.ZNode,
    explicit: bool,
) !void {
    var alias = try tree.addNode(parent, .{ .String = self.alias });

    switch (self.src) {
        .pkg => |pkg| if (!explicit and
            std.mem.eql(u8, self.alias, pkg.name) and
            std.mem.eql(u8, pkg.repository, api.default_repo))
        {
            var fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(&arena.allocator);
            try fifo.writer().print("{s}/{s}", .{ pkg.user, pkg.name });
            alias.value.String = fifo.readableSlice(0);
            _ = try tree.addNode(alias, .{ .String = pkg.ver_str });
        } else {
            var src = try tree.addNode(alias, .{ .String = "src" });
            var node = try tree.addNode(src, .{ .String = "pkg" });

            try zPutKeyString(tree, node, "user", pkg.user);
            if (explicit or !std.mem.eql(u8, pkg.name, self.alias)) {
                try zPutKeyString(tree, node, "name", pkg.name);
            }

            try zPutKeyString(tree, node, "version", pkg.ver_str);
            if (explicit or !std.mem.eql(u8, pkg.repository, api.default_repo)) {
                try zPutKeyString(tree, node, "repository", pkg.repository);
            }
        },
        .github => |gh| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            var github = try tree.addNode(src, .{ .String = "github" });
            try zPutKeyString(tree, github, "user", gh.user);
            try zPutKeyString(tree, github, "repo", gh.repo);
            try zPutKeyString(tree, github, "ref", gh.ref);

            if (explicit or !std.mem.eql(u8, gh.root, "src/main.zig")) {
                try zPutKeyString(tree, alias, "root", gh.root);
            }
        },
        .url => |url| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            try zPutKeyString(tree, src, "url", url.str);

            if (explicit or !std.mem.eql(u8, url.root, "src/main.zig")) {
                try zPutKeyString(tree, alias, "root", url.root);
            }
        },
        .local => |local| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            try zPutKeyString(tree, src, "local", local.path);

            if (explicit or !std.mem.eql(u8, local.root, "src/main.zig")) {
                try zPutKeyString(tree, alias, "root", local.root);
            }
        },
    }
}

fn expectZzzEqual(expected: *zzz.ZNode, actual: *zzz.ZNode) void {
    var expected_it: *zzz.ZNode = expected;
    var actual_it: *zzz.ZNode = actual;

    var expected_depth: isize = 0;
    var actual_depth: isize = 0;

    while (expected_it.next(&expected_depth)) |exp| : (expected_it = exp) {
        if (actual_it.next(&actual_depth)) |act| {
            defer actual_it = act;

            testing.expectEqual(expected_depth, actual_depth);
            switch (exp.value) {
                .String => |str| testing.expectEqualStrings(str, act.value.String),
                .Int => |int| testing.expectEqual(int, act.value.Int),
                .Float => |float| testing.expectEqual(float, act.value.Float),
                .Bool => |b| testing.expectEqual(b, act.value.Bool),
                else => {},
            }
        } else {
            testing.expect(false);
        }
    }

    testing.expectEqual(
        expected_it.next(&expected_depth),
        actual_it.next(&actual_depth),
    );
}

fn serializeTest(from: []const u8, to: []const u8, explicit: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dep = try fromString(from);
    var actual = zzz.ZTree(1, 1000){};
    var actual_root = try actual.addNode(null, .{ .Null = {} });
    try dep.addToZNode(&arena, &actual, actual_root, explicit);
    var expected = zzz.ZTree(1, 1000){};
    const expected_root = try expected.appendText(to);

    expectZzzEqual(expected_root, actual_root);
}

test "serialize pkg non-explicit" {
    const str =
        \\something:
        \\  src:
        \\    pkg:
        \\      user: test
        \\      version: ^0.0.0
        \\
    ;

    const expected = "test/something: ^0.0.0";

    try serializeTest(str, expected, false);
}

test "serialize pkg explicit" {
    const str =
        \\something:
        \\  src:
        \\    pkg:
        \\      user: test
        \\      version: ^0.0.0
        \\
    ;

    const expected =
        \\something:
        \\  src:
        \\    pkg:
        \\      user: test
        \\      name: something
        \\      version: ^0.0.0
        \\      repository: astrolabe.pm
        \\
    ;

    try serializeTest(str, expected, true);
}

test "serialize github non-explicit" {
    const str =
        \\something:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: my_repo
        \\      ref: master
        \\  root: main.zig
        \\
    ;

    try serializeTest(str, str, false);
}

test "serialize github non-explicit, default root" {
    const str =
        \\something:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: my_repo
        \\      ref: master
        \\
    ;

    try serializeTest(str, str, false);
}

test "serialize github explicit, default root" {
    const str =
        \\something:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: my_repo
        \\      ref: master
        \\  root: src/main.zig
        \\
    ;

    try serializeTest(str, str, true);
}

test "serialize github explicit" {
    const from =
        \\something:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: my_repo
        \\      ref: master
        \\
    ;

    const to =
        \\something:
        \\  src:
        \\    github:
        \\      user: test
        \\      repo: my_repo
        \\      ref: master
        \\  root: src/main.zig
        \\
    ;

    try serializeTest(from, to, true);
}

test "serialize url non-explicit" {
    const str =
        \\something:
        \\  src:
        \\    url: "https://github.com"
        \\  root: main.zig
        \\
    ;

    try serializeTest(str, str, false);
}

test "serialize url explicit" {
    const from =
        \\something:
        \\  src:
        \\    url: "https://github.com"
        \\
    ;

    const to =
        \\something:
        \\  src:
        \\    url: "https://github.com"
        \\  root: src/main.zig
        \\
    ;

    try serializeTest(from, to, true);
}
