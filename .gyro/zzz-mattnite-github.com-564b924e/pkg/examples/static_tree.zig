pub const std = @import("std");
pub const zzz = @import("zzz");

const kobold = @embedFile("../example-data/kobold.zzz");
const json_example = @embedFile("../example-data/json-example-3.zzz");

pub fn main() !void {
    // The kobold has exactly 51 nodes.
    var tree = zzz.ZTree(1, 51){};
    // Append the text to the tree. This creates a new root.
    const node = try tree.appendText(kobold);
    std.debug.print("Roots: {}\n", .{tree.rootSlice().len});
    // Convert strings to integer, floating, or boolean types.
    node.convertStrings();
    // Debug print.
    tree.show();

    std.debug.print("Number of nodes: {}\n", .{tree.node_count});
    // This function searches all the node's descendants.
    std.debug.print("Kobold's CON: {}\n", .{node.findNthDescendant(0, .{ .String = "con" }).?.child.?.value.Int});

    // The JSON example has exactly 161 nodes.
    var big_tree = zzz.ZTree(1, 161){};
    const root = try big_tree.appendText(json_example);
    root.convertStrings();
    big_tree.show();

    // Find all servlet names.
    var depth: isize = 0;
    var iter = root;
    while (iter.next(&depth)) |n| : (iter = n) {
        if (n.value.equals(.{ .String = "servlet-name" })) {
            if (n.child) |child| {
                std.debug.print("servlet-name: {}\n", .{child.value});
            }
        }
    }

    std.debug.print("Number of nodes: {}\n", .{big_tree.node_count});
}
