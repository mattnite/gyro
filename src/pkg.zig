const std = @import("std");
const version = @import("version");
const zzz = @import("zzz");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const api = @import("api.zig");
const cache = @import("cache.zig");
const utils = @import("utils.zig");
const local = @import("local.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;

pub const name = "pkg";
pub const Resolution = version.Semver;
pub const ResolutionEntry = struct {
    repository: []const u8,
    user: []const u8,
    name: []const u8,
    semver: version.Semver,
    dep_idx: ?usize,

    pub fn format(
        entry: ResolutionEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        try writer.print("{s}/{s}/{s}: {} -> {}", .{
            entry.repository,
            entry.user,
            entry.name,
            entry.semver,
            entry.dep_idx,
        });
    }
};
pub const FetchError = @typeInfo(@typeInfo(@TypeOf(api.getLatest)).Fn.return_type.?).ErrorUnion.error_set ||
    @typeInfo(@typeInfo(@TypeOf(fetch)).Fn.return_type.?).ErrorUnion.error_set;

const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    const repo = it.next() orelse return error.NoRepo;
    try resolutions.append(allocator, .{
        .repository = if (std.mem.eql(u8, repo, "default")) "astrolabe.pm" else repo,
        .user = it.next() orelse return error.NoUser,
        .name = it.next() orelse return error.NoName,
        .semver = try version.Semver.parse(allocator, it.next() orelse return error.NoVersion),
        .dep_idx = null,
    });
}

pub fn serializeResolutions(
    resolutions: []const ResolutionEntry,
    writer: anytype,
) !void {
    for (resolutions) |resolution|
        if (resolution.dep_idx != null)
            try writer.print("pkg {s} {s} {s} {}\n", .{
                resolution.repository,
                resolution.user,
                resolution.name,
                resolution.semver,
            });
}

fn findResolution(dep: Dependency.Source, resolutions: []const ResolutionEntry) ?usize {
    return for (resolutions) |entry, j| {
        if (std.mem.eql(u8, dep.pkg.repository, entry.repository) and
            std.mem.eql(u8, dep.pkg.user, entry.user) and
            std.mem.eql(u8, dep.pkg.name, entry.name) and
            dep.pkg.version.contains(entry.semver))
        {
            break j;
        }
    } else null;
}

fn findMatch(dep_table: []const Dependency.Source, dep_idx: usize, edges: []const Engine.Edge) ?usize {
    // TODO: handle different version range kinds
    const dep = dep_table[dep_idx].pkg;
    return for (edges) |edge| {
        const other = dep_table[edge.to].pkg;
        if (std.mem.eql(u8, dep.repository, other.repository) and
            std.mem.eql(u8, dep.user, other.user) and
            std.mem.eql(u8, dep.name, other.name) and
            (dep.version.contains(other.version.min) or
            other.version.contains(dep.version.min)))
        {
            break edge.to;
        }
    } else null;
}

fn fetch(
    arena: *std.heap.ArenaAllocator,
    dep: Dependency.Source,
    semver: Resolution,
    deps: *std.ArrayListUnmanaged(Dependency),
    path: *?[]const u8,
) !void {
    const allocator = arena.child_allocator;
    const entry_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{}-{s}", .{
        dep.pkg.name,
        dep.pkg.user,
        semver,
        dep.pkg.repository,
    });
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    if (!try entry.isDone()) {
        try api.getPkg(
            allocator,
            dep.pkg.repository,
            dep.pkg.user,
            dep.pkg.name,
            semver,
            entry.dir,
        );

        try entry.done();
    }

    const manifest = try entry.dir.openFile("manifest.zzz", .{});
    defer manifest.close();

    const text = try manifest.reader().readAllAlloc(&arena.allocator, std.math.maxInt(usize));
    var ztree = zzz.ZTree(1, 1000){};
    var root = try ztree.appendText(text);
    if (utils.zFindChild(root, "deps")) |deps_node| {
        var it = utils.ZChildIterator.init(deps_node);
        while (it.next()) |node|
            try deps.append(
                allocator,
                try Dependency.fromZNode(allocator, node),
            );
    }

    const base_path = try std.fs.path.join(arena.child_allocator, &.{ ".gyro", entry_name, "pkg" });
    defer arena.child_allocator.free(base_path);

    try local.updateBasePaths(arena, base_path, deps);
    path.* = try std.fs.path.join(&arena.allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
        (try utils.zFindString(root, "root")) orelse {
            std.log.err("fatal: manifest missing pkg root path: {s}/{s}/{s} {}", .{
                dep.pkg.repository,
                dep.pkg.user,
                dep.pkg.name,
                semver,
            });
            return error.Explained;
        },
    });
}

pub fn dedupeResolveAndFetch(
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    const arena = &fetch_queue.items(.arena)[i];
    const dep_idx = fetch_queue.items(.edge)[i].to;
    if (findResolution(dep_table[dep_idx], resolutions)) |res_idx| {
        if (resolutions[res_idx].dep_idx) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else if (findMatch(dep_table, dep_idx, fetch_queue.items(.edge)[0..i])) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else {
            fetch_queue.items(.result)[i] = .{
                .fill_resolution = res_idx,
            };
        }
    } else if (findMatch(dep_table, dep_idx, fetch_queue.items(.edge)[0..i])) |idx| {
        fetch_queue.items(.result)[i] = .{
            .replace_me = idx,
        };

        return;
    } else {
        fetch_queue.items(.result)[i] = .{
            .new_entry = try api.getLatest(
                &arena.allocator,
                dep_table[dep_idx].pkg.repository,
                dep_table[dep_idx].pkg.user,
                dep_table[dep_idx].pkg.name,
                dep_table[dep_idx].pkg.version,
            ),
        };
    }

    const resolution = switch (fetch_queue.items(.result)[i]) {
        .fill_resolution => |res_idx| resolutions[res_idx].semver,
        .new_entry => |semver| semver,
        else => unreachable,
    };

    try fetch(
        arena,
        dep_table[dep_idx],
        resolution,
        &fetch_queue.items(.deps)[i],
        &fetch_queue.items(.path)[i],
    );

    assert(fetch_queue.items(.path)[i] != null);
}

pub fn updateResolution(
    allocator: *Allocator,
    resolutions: *ResolutionTable,
    dep_table: []const Dependency.Source,
    fetch_queue: *FetchQueue,
    i: usize,
) !void {
    switch (fetch_queue.items(.result)[i]) {
        .fill_resolution => |res_idx| {
            const dep_idx = fetch_queue.items(.edge)[i].to;
            assert(resolutions.items[res_idx].dep_idx == null);
            resolutions.items[res_idx].dep_idx = dep_idx;
        },
        .new_entry => |semver| {
            const dep_idx = fetch_queue.items(.edge)[i].to;
            const pkg = &dep_table[dep_idx].pkg;
            try resolutions.append(allocator, .{
                .repository = pkg.repository,
                .user = pkg.user,
                .name = pkg.name,
                .semver = semver,
                .dep_idx = dep_idx,
            });
        },
        .replace_me => |dep_idx| fetch_queue.items(.edge)[i].to = dep_idx,
        .err => |err| return err,
        else => unreachable,
    }
}

test "deserializeLockfileEntry" {
    const lines = [_][]const u8{
        "default matt something 0.1.0",
        "my_own_repository matt foo 0.2.0",
    };

    var expected = ResolutionTable{};
    defer expected.deinit(testing.allocator);

    try expected.append(testing.allocator, .{
        .repository = "astrolabe.pm",
        .user = "matt",
        .name = "something",
        .semver = .{
            .major = 0,
            .minor = 1,
            .patch = 0,
        },
        .dep_idx = null,
    });
    try expected.append(testing.allocator, .{
        .repository = "my_own_repository",
        .user = "matt",
        .name = "foo",
        .semver = .{
            .major = 0,
            .minor = 2,
            .patch = 0,
        },
        .dep_idx = null,
    });

    var resolutions = ResolutionTable{};
    defer resolutions.deinit(testing.allocator);

    for (lines) |line| {
        var it = std.mem.tokenize(u8, line, " ");
        try deserializeLockfileEntry(testing.allocator, &it, &resolutions);
    }

    for (resolutions.items) |resolution, i| {
        try testing.expectEqualStrings(expected.items[i].repository, resolution.repository);
        try testing.expectEqualStrings(expected.items[i].user, resolution.user);
        try testing.expectEqualStrings(expected.items[i].name, resolution.name);
        try testing.expectEqual(expected.items[i].semver, resolution.semver);
    }
}

test "serializeResolutions" {
    var resolutions = ResolutionTable{};
    defer resolutions.deinit(testing.allocator);

    try resolutions.append(testing.allocator, .{
        .repository = "astrolabe.pm",
        .user = "matt",
        .name = "something",
        .semver = .{
            .major = 0,
            .minor = 1,
            .patch = 0,
        },
        .dep_idx = null,
    });
    try resolutions.append(testing.allocator, .{
        .repository = "my_own_repository",
        .user = "matt",
        .name = "foo",
        .semver = .{
            .major = 0,
            .minor = 2,
            .patch = 0,
        },
        .dep_idx = null,
    });

    var buf: [4096]u8 = undefined;
    var fb = std.io.fixedBufferStream(&buf);

    const expected =
        \\pkg astrolabe.pm matt something 0.1.0
        \\pkg my_own_repository matt foo 0.2.0
        \\
    ;

    try serializeResolutions(resolutions.items, fb.writer());
    try testing.expectEqualStrings(expected, buf[0..expected.len]);
}

test "dedupeResolveAndFetch: existing resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const dep = Dependency.Source{
        .pkg = .{
            .repository = "astrolabe.pm",
            .user = "matt",
            .name = "foo",
            .version = .{
                .min = .{
                    .major = 0,
                    .minor = 2,
                    .patch = 0,
                },
                .kind = .caret,
            },
        },
    };

    const resolution = ResolutionEntry{
        .repository = "astrolabe.pm",
        .user = "matt",
        .name = "foo",
        .semver = .{
            .major = 0,
            .minor = 2,
            .patch = 0,
        },
        .dep_idx = 5,
    };

    var fetch_queue = FetchQueue{};
    defer fetch_queue.deinit(testing.allocator);

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 0,
            .alias = "blarg",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    try dedupeResolveAndFetch(&arena, &.{dep}, &.{resolution}, &fetch_queue, 0);
    try testing.expectEqual(resolution.dep_idx, fetch_queue.items(.result)[0].replace_me);
}

test "dedupeResolveAndFetch: resolution without index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const dep = Dependency.Source{
        .pkg = .{
            .repository = "astrolabe.pm",
            .user = "mattnite",
            .name = "version",
            .version = .{
                .min = .{
                    .major = 0,
                    .minor = 1,
                    .patch = 0,
                },
                .kind = .caret,
            },
        },
    };

    var resolutions = ResolutionTable{};
    defer resolutions.deinit(testing.allocator);

    try resolutions.append(testing.allocator, .{
        .repository = "astrolabe.pm",
        .user = "mattnite",
        .name = "glob",
        .semver = .{
            .major = 0,
            .minor = 0,
            .patch = 0,
        },
        .dep_idx = null,
    });

    try resolutions.append(testing.allocator, .{
        .repository = "astrolabe.pm",
        .user = "mattnite",
        .name = "version",
        .semver = .{
            .major = 0,
            .minor = 1,
            .patch = 0,
        },
        .dep_idx = null,
    });

    var fetch_queue = FetchQueue{};
    defer fetch_queue.deinit(testing.allocator);

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 0,
            .alias = "blarg",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    try dedupeResolveAndFetch(&arena, &.{dep}, resolutions.items, &fetch_queue, 0);
    try testing.expectEqual(@as(usize, 1), fetch_queue.items(.result)[0].fill_resolution);

    try updateResolution(testing.allocator, &resolutions, &.{dep}, fetch_queue, 0);
    try testing.expectEqual(@as(?usize, 0), resolutions.items[1].dep_idx);
}

test "dedupeResolveAndFetch: new entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const deps = &.{
        Dependency.Source{
            .pkg = .{
                .repository = "astrolabe.pm",
                .user = "mattnite",
                .name = "download",
                .version = .{
                    .min = .{
                        .major = 0,
                        .minor = 1,
                        .patch = 0,
                    },
                    .kind = .caret,
                },
            },
        },
        Dependency.Source{
            .pkg = .{
                .repository = "astrolabe.pm",
                .user = "mattnite",
                .name = "download",
                .version = .{
                    .min = .{
                        .major = 0,
                        .minor = 1,
                        .patch = 2,
                    },
                    .kind = .caret,
                },
            },
        },
    };

    var resolutions = ResolutionTable{};
    defer resolutions.deinit(testing.allocator);

    var fetch_queue = FetchQueue{};
    defer fetch_queue.deinit(testing.allocator);

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 0,
            .alias = "foo",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 1,
            .alias = "blarg",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    for (fetch_queue.items(.edge)) |_, i|
        try dedupeResolveAndFetch(&arena, deps, resolutions.items, &fetch_queue, i);

    for (fetch_queue.items(.edge)) |_, i|
        try updateResolution(testing.allocator, &resolutions, deps, fetch_queue, i);

    try testing.expect(fetch_queue.items(.result)[0] == .new_entry);
    try testing.expectEqual(@TypeOf(fetch_queue.items(.result)[0]){ .replace_me = 0 }, fetch_queue.items(.result)[1]);
    try testing.expectEqual(@as(usize, 0), fetch_queue.items(.result)[1].replace_me);
    try testing.expectEqual(@as(?usize, 0), resolutions.items[0].dep_idx);
}

test "dedupeResolveAndFetch: collision in batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const deps = &.{
        Dependency.Source{
            .pkg = .{
                .repository = "astrolabe.pm",
                .user = "mattnite",
                .name = "download",
                .version = .{
                    .min = .{
                        .major = 0,
                        .minor = 1,
                        .patch = 0,
                    },
                    .kind = .caret,
                },
            },
        },
        Dependency.Source{
            .pkg = .{
                .repository = "astrolabe.pm",
                .user = "mattnite",
                .name = "download",
                .version = .{
                    .min = .{
                        .major = 0,
                        .minor = 1,
                        .patch = 2,
                    },
                    .kind = .caret,
                },
            },
        },
    };

    var resolutions = ResolutionTable{};
    defer resolutions.deinit(testing.allocator);

    try resolutions.append(testing.allocator, .{
        .repository = "astrolabe.pm",
        .user = "mattnite",
        .name = "download",
        .semver = .{
            .major = 0,
            .minor = 1,
            .patch = 2,
        },
        .dep_idx = null,
    });

    var fetch_queue = FetchQueue{};
    defer fetch_queue.deinit(testing.allocator);

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 0,
            .alias = "foo",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    try fetch_queue.append(testing.allocator, .{
        .edge = .{
            .from = .{
                .root = .normal,
            },
            .to = 1,
            .alias = "blarg",
        },
        .deps = std.ArrayListUnmanaged(Dependency){},
    });

    for (fetch_queue.items(.edge)) |_, i|
        try dedupeResolveAndFetch(&arena, deps, resolutions.items, &fetch_queue, i);

    for (fetch_queue.items(.edge)) |_, i|
        try updateResolution(testing.allocator, &resolutions, deps, fetch_queue, i);

    try testing.expectEqual(@as(usize, 0), fetch_queue.items(.result)[0].fill_resolution);
    try testing.expectEqual(fetch_queue.items(.edge)[0].to, fetch_queue.items(.result)[1].replace_me);
    try testing.expectEqual(@as(?usize, 0), resolutions.items[0].dep_idx);
}
