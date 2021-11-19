const std = @import("std");
const zzz = @import("zzz");

pub const default_repo = "astrolabe.pm";
pub const default_root = "src/main.zig";

pub const ZChildIterator = struct {
    val: ?*zzz.ZNode,

    pub fn next(self: *ZChildIterator) ?*zzz.ZNode {
        return if (self.val) |node| blk: {
            self.val = node.sibling;
            break :blk node;
        } else null;
    }

    pub fn init(node: *zzz.ZNode) ZChildIterator {
        return ZChildIterator{
            .val = node.child,
        };
    }
};

pub fn zFindChild(node: *zzz.ZNode, key: []const u8) ?*zzz.ZNode {
    var it = ZChildIterator.init(node);
    return while (it.next()) |child| {
        switch (child.value) {
            .String => |str| if (std.mem.eql(u8, str, key)) break child,
            else => continue,
        }
    } else null;
}

pub fn zGetString(node: *const zzz.ZNode) ![]const u8 {
    return switch (node.value) {
        .String => |str| str,
        else => {
            return error.NotAString;
        },
    };
}

pub fn zFindString(parent: *zzz.ZNode, key: []const u8) !?[]const u8 {
    return if (zFindChild(parent, key)) |node|
        if (node.child) |child|
            try zGetString(child)
        else
            null
    else
        null;
}

pub fn zPutKeyString(tree: *zzz.ZTree(1, 1000), parent: *zzz.ZNode, key: []const u8, value: []const u8) !void {
    var node = try tree.addNode(parent, .{ .String = key });
    _ = try tree.addNode(node, .{ .String = value });
}

pub const UserRepoResult = struct {
    user: []const u8,
    repo: []const u8,
};

pub fn parseUserRepo(str: []const u8) !UserRepoResult {
    if (std.mem.count(u8, str, "/") != 1) {
        std.log.err("need to have a single '/' in {s}", .{str});
        return error.Explained;
    }

    var it = std.mem.tokenize(u8, str, "/");
    return UserRepoResult{
        .user = it.next().?,
        .repo = it.next().?,
    };
}

/// trim 'zig-' prefix and '-zig' or '.zig' suffixes from a name
pub fn normalizeName(name: []const u8) ![]const u8 {
    const prefix = "zig-";
    const dot_suffix = ".zig";
    const dash_suffix = "-zig";

    const begin = if (std.mem.startsWith(u8, name, prefix)) prefix.len else 0;
    const end = if (std.mem.endsWith(u8, name, dot_suffix))
        name.len - dot_suffix.len
    else if (std.mem.endsWith(u8, name, dash_suffix))
        name.len - dash_suffix.len
    else
        name.len;

    if (begin > end)
        return error.Overlap
    else if (begin == end)
        return error.Empty;

    return name[begin..end];
}

pub fn escape(allocator: *std.mem.Allocator, str: []const u8) ![]const u8 {
    return for (str) |c| {
        if (!std.ascii.isAlNum(c) and c != '_') {
            var buf = try allocator.alloc(u8, str.len + 3);
            std.mem.copy(u8, buf, "@\"");
            std.mem.copy(u8, buf[2..], str);
            buf[buf.len - 1] = '"';
            break buf;
        }
    } else try allocator.dupe(u8, str);
}

pub fn joinPathConvertSep(arena: *@import("ThreadSafeArenaAllocator.zig"), inputs: []const []const u8) ![]const u8 {
    const allocator = arena.child_allocator;
    var components = try std.ArrayList([]const u8).initCapacity(allocator, inputs.len);
    defer {
        for (components.items) |comp|
            allocator.free(comp);

        components.deinit();
    }

    for (inputs) |input|
        try components.append(try std.mem.replaceOwned(
            u8,
            allocator,
            input,
            std.fs.path.sep_str_posix,
            std.fs.path.sep_str,
        ));

    return std.fs.path.join(&arena.allocator, components.items);
}

test "normalize zig-zig" {
    try std.testing.expectError(error.Overlap, normalizeName("zig-zig"));
}

test "normalize zig-.zig" {
    try std.testing.expectError(error.Empty, normalizeName("zig-.zig"));
}

test "normalize SDL.zig" {
    try std.testing.expectEqualStrings("SDL", try normalizeName("SDL.zig"));
}

test "normalize zgl" {
    try std.testing.expectEqualStrings("zgl", try normalizeName("zgl"));
}

test "normalize zig-args" {
    try std.testing.expectEqualStrings("args", try normalizeName("zig-args"));
}

test "normalize vulkan-zig" {
    try std.testing.expectEqualStrings("vulkan", try normalizeName("vulkan-zig"));
}

test "normalize known-folders" {
    try std.testing.expectEqualStrings("known-folders", try normalizeName("known-folders"));
}
