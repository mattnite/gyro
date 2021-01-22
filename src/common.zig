const std = @import("std");
const zzz = @import("zzz");

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
            std.log.debug("{}\n", .{node.value});
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

pub fn zPutKeyString(tree: *zzz.ZTree(1, 100), parent: *zzz.ZNode, key: []const u8, value: []const u8) !void {
    var node = try tree.addNode(parent, .{ .String = key });
    _ = try tree.addNode(node, .{ .String = value });
}

pub const UserRepoResult = struct {
    user: []const u8,
    repo: []const u8,
};

pub fn parseUserRepo(link: []const u8) !UserRepoResult {
    const info = blk: {
        const gh_url = "github.com";
        const begin = if (std.mem.indexOf(u8, link, gh_url)) |i|
            if (link.len >= i + gh_url.len + 1) i + gh_url.len + 1 else {
                std.log.err("couldn't parse link", .{});
                return error.Explained;
            }
        else
            0;
        const end = if (std.mem.endsWith(u8, link, ".git")) link.len - 4 else link.len;

        const ret = link[begin..end];
        if (std.mem.count(u8, ret, "/") != 1) {
            std.log.err(
                "got '{s}' from '{s}', it needs to have a single '/' so I can figure out the user/repo",
                .{ ret, link },
            );
            return error.Explained;
        }

        break :blk ret;
    };

    var it = std.mem.tokenize(info, "/");
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

test "normalize zig-zig" {
    std.testing.expectError(error.Overlap, normalizeName("zig-zig"));
}

test "normalize zig-.zig" {
    std.testing.expectError(error.Empty, normalizeName("zig-.zig"));
}

test "normalize SDL.zig" {
    std.testing.expectEqualStrings("SDL", try normalizeName("SDL.zig"));
}

test "normalize zgl" {
    std.testing.expectEqualStrings("zgl", try normalizeName("zgl"));
}

test "normalize zig-args" {
    std.testing.expectEqualStrings("args", try normalizeName("zig-args"));
}

test "normalize vulkan-zig" {
    std.testing.expectEqualStrings("vulkan", try normalizeName("vulkan-zig"));
}

test "normalize known-folders" {
    std.testing.expectEqualStrings("known-folders", try normalizeName("known-folders"));
}
