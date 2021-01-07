const std = @import("std");
const zzz = @import("zzz");

pub const default_root = "src/main.zig";

pub const ZChildIterator = struct {
    val: ?*const zzz.ZNode,

    pub fn next(self: *ZChildIterator) ?*const zzz.ZNode {
        return if (self.val) |node| blk: {
            self.val = node.sibling;
            break :blk node;
        } else null;
    }

    pub fn init(node: *const zzz.ZNode) ZChildIterator {
        return ZChildIterator{
            .val = node.child,
        };
    }
};

pub fn zFindChild(node: *const zzz.ZNode, key: []const u8) ?*const zzz.ZNode {
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

pub fn zFindString(parent: *const zzz.ZNode, key: []const u8) !?[]const u8 {
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
