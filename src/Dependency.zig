const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const uri = @import("uri");
const api = @import("api.zig");
const utils = @import("utils.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const mem = std.mem;
const testing = std.testing;

pub const SourceType = std.meta.TagType(Source);

alias: []const u8,
src: Source,

pub const Source = union(enum) {
    pkg: struct {
        user: []const u8,
        name: []const u8,
        version: version.Range,
        repository: []const u8,
    },
    github: struct {
        user: []const u8,
        repo: []const u8,
        ref: []const u8,
        root: ?[]const u8,
    },
    url: struct {
        str: []const u8,
        root: ?[]const u8,
    },
    local: struct {
        path: []const u8,
        root: ?[]const u8,
    },

    pub fn format(
        source: Source,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        switch (source) {
            .pkg => |pkg| try writer.print("{s}/{s}/{s}: {}", .{ pkg.repository, pkg.user, pkg.name, pkg.version }),
            .github => |gh| try writer.print("github.com/{s}/{s}/{s}: {s}", .{ gh.user, gh.repo, gh.root, gh.ref }),
            .url => |url| try writer.print("{s}/{s}", .{ url.str, url.root }),
            .local => |local| try writer.print("{s}/{s}", .{ local.path, local.root }),
        }
    }
};

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
pub fn fromZNode(allocator: *Allocator, node: *zzz.ZNode) !Self {
    if (node.*.child == null) return error.NoChildren;

    // check if only one child node and that it has no children
    if (node.*.child.?.value == .String and node.*.child.?.child == null) {
        if (node.*.child.?.sibling != null) return error.Unknown;
        const key = try utils.zGetString(node);

        const info = try utils.parseUserRepo(key);
        const ver_str = try utils.zGetString(node.*.child.?);
        return Self{
            .alias = info.repo,
            .src = .{
                .pkg = .{
                    .user = info.user,
                    .name = info.repo,
                    .version = try version.Range.parse(allocator, ver_str),
                    .repository = utils.default_repo,
                },
            },
        };
    }

    // search for src node
    const alias = try utils.zGetString(node);
    const src_node = blk: {
        var it = utils.ZChildIterator.init(node);

        while (it.next()) |child| {
            switch (child.value) {
                .String => |str| if (mem.eql(u8, str, "src")) break :blk child,
                else => continue,
            }
        } else return error.SrcTagNotFound;
    };

    const src: Source = blk: {
        const child = src_node.child orelse return error.SrcNeedsChild;
        const src_str = try utils.zGetString(child);
        const src_type = inline for (std.meta.fields(SourceType)) |field| {
            if (mem.eql(u8, src_str, field.name)) break @field(SourceType, field.name);
        } else return error.InvalidSrcTag;

        break :blk switch (src_type) {
            .pkg => .{
                .pkg = .{
                    .user = (try utils.zFindString(child, "user")) orelse return error.MissingUser,
                    .name = (try utils.zFindString(child, "name")) orelse alias,
                    .version = try version.Range.parse(allocator, (try utils.zFindString(child, "version")) orelse return error.MissingVersion),
                    .repository = (try utils.zFindString(child, "repository")) orelse utils.default_repo,
                },
            },
            .github => .{
                .github = .{
                    .user = (try utils.zFindString(child, "user")) orelse return error.GithubMissingUser,
                    .repo = (try utils.zFindString(child, "repo")) orelse return error.GithubMissingRepo,
                    .ref = (try utils.zFindString(child, "ref")) orelse return error.GithubMissingRef,
                    .root = try utils.zFindString(node, "root"),
                },
            },
            .url => .{
                .url = .{
                    .str = try utils.zGetString(child.child orelse return error.UrlMissingStr),
                    .root = try utils.zFindString(node, "root"),
                },
            },
            .local => .{
                .local = .{
                    .path = try utils.zGetString(child.child orelse return error.UrlMissingStr),
                    .root = try utils.zFindString(node, "root"),
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
                else => return err,
            }
            return error.Explained;
        };
    }

    // TODO: integrity

    return Self{ .alias = alias, .src = src };
}

/// for testing
fn fromString(allocator: *Allocator, str: []const u8) !Self {
    var tree = zzz.ZTree(1, 1000){};
    const root = try tree.appendText(str);
    return Self.fromZNode(allocator, root.*.child.?);
}

fn expectNullStrEqual(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |e| if (actual) |a| {
        try testing.expectEqualStrings(e, a);
        return;
    };

    try testing.expectEqual(expected, actual);
}

fn expectDepEqual(expected: Self, actual: Self) !void {
    try testing.expectEqualStrings(expected.alias, actual.alias);
    try testing.expectEqual(@as(SourceType, expected.src), @as(SourceType, actual.src));

    return switch (expected.src) {
        .pkg => |pkg| {
            try testing.expectEqualStrings(pkg.user, actual.src.pkg.user);
            try testing.expectEqualStrings(pkg.name, actual.src.pkg.name);
            try testing.expectEqualStrings(pkg.repository, actual.src.pkg.repository);
            try testing.expectEqual(pkg.version, actual.src.pkg.version);
        },
        .github => |gh| {
            try testing.expectEqualStrings(gh.user, actual.src.github.user);
            try testing.expectEqualStrings(gh.repo, actual.src.github.repo);
            try testing.expectEqualStrings(gh.ref, actual.src.github.ref);
            try expectNullStrEqual(gh.root, actual.src.github.root);
        },
        .url => |url| {
            try testing.expectEqualStrings(url.str, actual.src.url.str);
            try expectNullStrEqual(url.root, actual.src.url.root);
        },
        .local => |local| {
            try testing.expectEqualStrings(local.path, actual.src.local.path);
            try expectNullStrEqual(local.root, actual.src.local.root);
        },
    };
}

test "default repo pkg" {
    try expectDepEqual(Self{
        .alias = "something",
        .src = .{
            .pkg = .{
                .user = "matt",
                .name = "something",
                .version = try version.Range.parse(testing.allocator, "^0.1.0"),
                .repository = utils.default_repo,
            },
        },
    }, try fromString(testing.allocator, "matt/something: ^0.1.0"));
}

test "aliased, default repo pkg" {
    const actual = try fromString(testing.allocator,
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
                .version = try version.Range.parse(testing.allocator, "^0.1.0"),
                .repository = utils.default_repo,
            },
        },
    };

    try expectDepEqual(expected, actual);
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
    const actual = try fromString(testing.allocator,
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
                .version = try version.Range.parse(testing.allocator, "^0.1.0"),
                .repository = "example.com",
            },
        },
    };

    try expectDepEqual(expected, actual);
}

test "aliased, non-default repo pkg" {
    const actual = try fromString(testing.allocator,
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
                .version = try version.Range.parse(testing.allocator, "^0.1.0"),
                .repository = "example.com",
            },
        },
    };

    try expectDepEqual(expected, actual);
}

test "github default root" {
    const actual = try fromString(testing.allocator,
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
                .root = null,
            },
        },
    };

    try expectDepEqual(expected, actual);
}

test "github explicit root" {
    const actual = try fromString(testing.allocator,
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

    try expectDepEqual(expected, actual);
}

test "raw default root" {
    const actual = try fromString(testing.allocator,
        \\foo:
        \\  src:
        \\    url: "https://astrolabe.pm"
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .url = .{
                .str = "https://astrolabe.pm",
                .root = null,
            },
        },
    };

    try expectDepEqual(expected, actual);
}

test "raw explicit root" {
    const actual = try fromString(testing.allocator,
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

    try expectDepEqual(expected, actual);
}

test "local with default root" {
    const actual = try fromString(testing.allocator,
        \\foo:
        \\  src:
        \\    local: "mypkgs/cool-project"
    );

    const expected = Self{
        .alias = "foo",
        .src = .{
            .local = .{
                .path = "mypkgs/cool-project",
                .root = null,
            },
        },
    };

    try expectDepEqual(expected, actual);
}

test "local with explicit root" {
    const actual = try fromString(testing.allocator,
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

    try expectDepEqual(expected, actual);
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
            std.mem.eql(u8, pkg.repository, utils.default_repo))
        {
            var fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(&arena.allocator);
            try fifo.writer().print("{s}/{s}", .{ pkg.user, pkg.name });
            alias.value.String = fifo.readableSlice(0);
            const ver_str = try std.fmt.allocPrint(&arena.allocator, "{}", .{pkg.version});
            _ = try tree.addNode(alias, .{ .String = ver_str });
        } else {
            var src = try tree.addNode(alias, .{ .String = "src" });
            var node = try tree.addNode(src, .{ .String = "pkg" });

            try utils.zPutKeyString(tree, node, "user", pkg.user);
            if (explicit or !std.mem.eql(u8, pkg.name, self.alias)) {
                try utils.zPutKeyString(tree, node, "name", pkg.name);
            }

            const ver_str = try std.fmt.allocPrint(&arena.allocator, "{}", .{pkg.version});
            try utils.zPutKeyString(tree, node, "version", ver_str);
            if (explicit or !std.mem.eql(u8, pkg.repository, utils.default_repo)) {
                try utils.zPutKeyString(tree, node, "repository", pkg.repository);
            }
        },
        .github => |gh| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            var github = try tree.addNode(src, .{ .String = "github" });
            try utils.zPutKeyString(tree, github, "user", gh.user);
            try utils.zPutKeyString(tree, github, "repo", gh.repo);
            try utils.zPutKeyString(tree, github, "ref", gh.ref);

            if (explicit or gh.root != null) {
                try utils.zPutKeyString(tree, alias, "root", gh.root orelse utils.default_root);
            }
        },
        .url => |url| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            try utils.zPutKeyString(tree, src, "url", url.str);

            if (explicit or url.root != null) {
                try utils.zPutKeyString(tree, alias, "root", url.root orelse utils.default_root);
            }
        },
        .local => |local| {
            var src = try tree.addNode(alias, .{ .String = "src" });
            try utils.zPutKeyString(tree, src, "local", local.path);

            if (explicit or local.root != null) {
                try utils.zPutKeyString(tree, alias, "root", local.root orelse utils.default_root);
            }
        },
    }
}

fn expectZzzEqual(expected: *zzz.ZNode, actual: *zzz.ZNode) !void {
    var expected_it: *zzz.ZNode = expected;
    var actual_it: *zzz.ZNode = actual;

    var expected_depth: isize = 0;
    var actual_depth: isize = 0;

    while (expected_it.next(&expected_depth)) |exp| : (expected_it = exp) {
        if (actual_it.next(&actual_depth)) |act| {
            defer actual_it = act;

            try testing.expectEqual(expected_depth, actual_depth);
            switch (exp.value) {
                .String => |str| try testing.expectEqualStrings(str, act.value.String),
                .Int => |int| try testing.expectEqual(int, act.value.Int),
                .Float => |float| try testing.expectEqual(float, act.value.Float),
                .Bool => |b| try testing.expectEqual(b, act.value.Bool),
                else => {},
            }
        } else {
            try testing.expect(false);
        }
    }

    try testing.expectEqual(
        expected_it.next(&expected_depth),
        actual_it.next(&actual_depth),
    );
}

fn serializeTest(from: []const u8, to: []const u8, explicit: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dep = try fromString(testing.allocator, from);
    var actual = zzz.ZTree(1, 1000){};
    var actual_root = try actual.addNode(null, .{ .Null = {} });
    try dep.addToZNode(&arena, &actual, actual_root, explicit);
    var expected = zzz.ZTree(1, 1000){};
    const expected_root = try expected.appendText(to);

    try expectZzzEqual(expected_root, actual_root);
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
