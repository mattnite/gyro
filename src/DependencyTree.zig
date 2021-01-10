const std = @import("std");
const Dependency = @import("Dependency.zig");
const Lockfile = @import("Lockfile.zig");

const Self = @This();
const Allocator = std.mem.Allocator;
const DepQueue = std.TailQueue(struct {
    from: *Node,
    dep: *Dependency,
});

allocator: *Allocator,
dep_pool: std.ArrayListUnmanaged(Dependency),
edge_pool: std.ArrayListUnmanaged(Edge),
node_pool: std.ArrayListUnmanaged(Node),
buf_pool: std.ArrayListUnmanaged([]const u8),
root: Node,

const Node = struct {
    entry: *const Lockfile.Entry,
    depth: u32,
    edges: std.ArrayListUnmanaged(*Edge),
};

const Edge = struct {
    from: *Node,
    to: *Node,
    dep: *const Dependency,
};

pub fn generate(
    allocator: *Allocator,
    lockfile: *Lockfile,
    deps: std.ArrayList(Dependency),
) !*Self {
    var ret = try allocator.create(Self);
    ret.* = Self{
        .allocator = allocator,
        .dep_pool = std.ArrayListUnmanaged(Dependency){},
        .edge_pool = std.ArrayListUnmanaged(Edge){},
        .node_pool = std.ArrayListUnmanaged(Node){},
        .buf_pool = std.ArrayListUnmanaged([]const u8){},
        .root = .{
            .entry = undefined,
            .depth = 0,
            .edges = std.ArrayListUnmanaged(*Edge){},
        },
    };
    errdefer ret.destroy();

    var queue = DepQueue{};
    defer while (queue.popFirst()) |node| allocator.destroy(node);

    try ret.dep_pool.appendSlice(allocator, deps.items);
    for (ret.dep_pool.items) |*dep| {
        var node = try allocator.create(DepQueue.Node);
        node.data = .{
            .from = &ret.root,
            .dep = dep,
        };

        queue.append(node);
    }

    while (queue.popFirst()) |q_node| {
        defer allocator.destroy(q_node);

        const entry = try q_node.data.dep.resolve(ret, lockfile);
        var node = for (ret.node_pool.items) |*node| {
            if (node.entry == entry) {
                node.depth = std.math.max(node.depth, q_node.data.from.depth + 1);
                break node;
            }
        } else blk: {
            try ret.node_pool.append(allocator, Node{
                .entry = entry,
                .depth = q_node.data.from.depth + 1,
                .edges = std.ArrayListUnmanaged(*Edge){},
            });

            const ptr = &ret.node_pool.items[ret.node_pool.items.len - 1];
            const dependencies = try entry.getDeps(ret);
            defer ret.allocator.free(dependencies);

            try ret.dep_pool.appendSlice(allocator, dependencies);
            var i: usize = 0;
            while (i < dependencies.len) : (i += 1) {
                var new_node = try allocator.create(DepQueue.Node);
                new_node.data = .{
                    .from = ptr,
                    .dep = &ret.dep_pool.items[ret.dep_pool.items.len -
                            dependencies.len + i],
                };
                queue.append(new_node);
            }

            break :blk ptr;
        };

        try ret.edge_pool.append(allocator, Edge{
            .from = q_node.data.from,
            .to = node,
            .dep = q_node.data.dep,
        });

        try q_node.data.from.edges.append(
            allocator,
            &ret.edge_pool.items[ret.edge_pool.items.len - 1],
        );

        try ret.validate();
    }

    return ret;
}

fn validate(self: Self) !void {
    for (self.node_pool.items) |node| {
        for (node.edges.items) |edge| {
            if (node.depth >= edge.to.depth) return error.CircularDependency;
        }
    }
}

pub fn destroy(self: *Self) void {
    self.root.edges.deinit(self.allocator);

    for (self.node_pool.items) |*node| node.edges.deinit(self.allocator);
    self.node_pool.deinit(self.allocator);

    self.dep_pool.deinit(self.allocator);
    self.edge_pool.deinit(self.allocator);

    for (self.buf_pool.items) |buf| self.allocator.free(buf);
    self.buf_pool.deinit(self.allocator);

    self.allocator.destroy(self);
}

pub fn printZig(self: Self, writer: anytype) !void {
    return error.Todo;
}

pub fn createArgs(
    self: Self,
    allocator: *Allocator,
) !std.ArrayList([]const u8) {
    return error.Todo;
}
