pub const std = @import("std");
pub const zzz = @import("zzz");

pub fn main() !void {
    // Creates a tree that can contain 2 roots and 100 nodes total. Internally this creates
    // 2 root pointers, and 100 nodes (48 bytes each on 64-bit).
    var tree = zzz.ZTree(2, 100){};
    // Create a root node with no parent and a value of .Null. Possible errors are TreeFull and
    // TooManyRoots.
    var root = try tree.addNode(null, .Null);

    // Add some properties.
    _ = try tree.addNode(try tree.addNode(root, .{ .String = "name" }), .{ .String = "Foobar" });
    // Build an array by add children to the same parent.
    var stats = try tree.addNode(root, .{ .String = "stats" });
    _ = try tree.addNode(try tree.addNode(stats, .{ .String = "health" }), .{ .Int = 10 });
    _ = try tree.addNode(try tree.addNode(stats, .{ .String = "mana" }), .{ .Int = 30 });

    root.show();
    // Basic output.
    var out = std.io.getStdOut().writer();
    try root.stringify(out);
    try out.writeAll("\n");
}
