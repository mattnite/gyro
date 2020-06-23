const std = @import("std");
const os = std.os;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;
const OutStream = std.fs.File.OutStream;

const DependencyGraph = struct {
    allocator: *Allocator,
    nodes: TailQueue(Node),
    queue: TailQueue(Node),

    const Self = @This();

    /// Create DependencyGraph given a root path
    fn init(allocator: *Allocator, path: []const u8) !DependencyGraph {
        var ret = DependencyGraph{
            .allocator = allocator,
            .nodes = TailQueue.init(),
            .queue = TailQueue.init(),
        };

        // TODO: get cwd of process
        ret.queue.append(try ret.queue.createNode(Node.init(allocator, ".", "", 0), allocator));
    }

    fn process(self: *Self) !void {
        var maybe_front = self.queue.popFirst();
        iterate: while (maybe_front) : (maybe_front = self.queue.popFirst()) {
            const front = maybe_front.?.data;

            // destroy if it already exists
            var cursor = self.nodes.first;
            while (cursor != null) : (cursor = cursor.next) {
                const node = cursor.?.data;
                if (std.mem.eql(u8, front.base_path, node.base_path) and
                    std.mem.eql(u8, front.version, node.version))
                {
                    self.queue.destroyNode(maybe_front.?, self.allocator);
                    continue :iterate;
                }
            }

            // compile pkg_runner

            // TODO: figure out some sort of system for keeping a giant buffer
            // of all the output of the pkg_runners where the strings can live,
            // and figure out how to do line by line iteration
            var lines = try front.fetch_dependencies();
            for (lines) |line| {
                // if not in nodes
                // set up edges
                // set depth to current + 1

                // else if it is in nodes and its depth is less than front
                // increase depth of node (in node list) to depth + 1
                // destroy dep

                // append to queue
            }

            try self.validate();
        }
    }

    /// Naive check for circular dependencies
    fn validate(self: *Self) !void {
        var cursor = self.nodes.first;
        while (cursor != null) : (cursor = cursor.next) {
            const node = cursor.?.data;

            for (node.dependencies.span()) |dep| {
                if (dep.node.depth <= node.depth) {
                    return error.CyclicalDependency;
                }
            }

            for (node.dependents.span()) |dep| {
                if (dep.node.depth >= node.depth) {
                    return error.CyclicalDependency;
                }
            }
        }
    }

    const DependencyEdge = struct {
        node: *Node,
        alias: []const u8,
        root: []const u8,
    };

    const DependentEdge = struct {
        node: *Node,
    };

    const Node = struct {
        dependencies: ArrayList(DependencyEdge),
        dependents: ArrayList(DependentEdge),

        base_path: []const u8,
        version: []const u8,
        depth: u32,

        fn init(allocator: *Allocator, base_path: []const u8, version: []const u8, depth: u32) !Node {
            return Node{
                .dependencies = ArrayList.init(),
                .dependents = ArrayList(),
                .base_path = base_path,
                .version = version,
                .depth = depth,
            };
        }

        fn compile_runner() !Runner {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const allocator = &arena.allocator;

            var build_buf: [std.os.PATH_MAX]u8 = undefined;
            const build_dir = try std.os.getcwd(&build_buf);
            const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ build_dir, "zig-cache" });

            std.debug.warn("build dir: {}\n", .{build_dir});
            std.debug.warn("cache dir: {}\n", .{cache_dir});

            const builder = try Builder.create(allocator, "zig", build_dir, cache_dir);
            defer builder.destroy();

            builder.resolveInstallPrefix();

            // normal build script
            const target = b.standardTargetOptions(.{});
            const mode = b.standardReleaseOptions();

            const exe = b.addExecutable("pkg_runner", "src/pkg_runner.zig");
            exe.setTarget(target);
            exe.setBuildMode(mode);
            exe.install();

            // TODO: this should just invoke the default step and build the program
            try b.make(&[_][]const u8{});

            return Runner{};
        }
    };
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var dep_graph = try DependencyGraph.init(allocator, ".");
    defer dep_graph.deinit();

    // steps of the program:
    // - create root of dependency graph
    // - compile and run pkg_runner
    // - read stdout of pkg_runner and create package objects, add package
    //   objects to graph
    try dep_graph.process();

    // generate package file
    var cache_dir = std.fs.Dir{ .fd = try os.open("zig-cache", os.O_DIRECTORY, 0) };
    defer cache_dir.close();

    const gen_file = try cache_dir.createFile("packages.zig", std.fs.File.CreateFlags{
        .truncate = true,
    });
    defer gen_file.close();
    // TODO: errdefer delete file

    const file_stream = gen_file.outStream();
    try file_stream.writeAll(
        \\const std = @import("std");
        \\const Pkg = std.build.Pkg;
        \\
        \\pub const list = [_]Pkg{
        \\
    );

    for (node.dependencies.span()) |dep| {
        try recursive_print(file_stream, dep, 1);
    }

    try file_stream.writeAll("};\n");
}

fn indent(stream: OutStream, n: usize) !void {
    try stream.writeByteNTimes(' ', n * 4);
}

fn recursive_print(stream: std.fs.File.OutStream, edge: *DependencyEdge, depth: usize) !void {
    try indent(stream, depth);
    try stream.print("Pkg{{]\n", .{});
    try indent(stream, depth + 1);
    try stream.print(".name = \"{}\",\n", .{});
    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{});

    if (node.dependencies.len) {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = &[_]Pkg{{\n", .{});

        for (node.dependencies.span()) |dep| {
            try recursive_print(stream, dep, depth + 2);
        }
    } else {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = null,\n", .{});
    }

    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{});
}
