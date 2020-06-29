const std = @import("std");
const os = std.os;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TailQueue = std.TailQueue;
const OutStream = std.fs.File.OutStream;
const ChildProcess = std.ChildProcess;
const ExecResult = std.ChildProcess.ExecResult;
const Builder = std.build.Builder;

const DependencyGraph = struct {
    allocator: *Allocator,
    nodes: TailQueue(Node),
    queue: TailQueue(Node),
    results: ArrayList(ExecResult),

    const Self = @This();

    /// Create DependencyGraph given a root path
    fn init(allocator: *Allocator, path: []const u8) !DependencyGraph {
        var ret = DependencyGraph{
            .allocator = allocator,
            .nodes = TailQueue(Node).init(),
            .queue = TailQueue(Node).init(),
            .results = ArrayList(ExecResult).init(allocator),
        };

        // TODO: get cwd of process
        ret.queue.append(try ret.queue.createNode(try Node.init(allocator, ".", "", 0), allocator));
        return ret;
    }

    fn deinit(self: *Self) void {
        for (self.results.span()) |result| {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        var cursor = self.queue.pop();
        while (cursor != null) : (cursor = self.queue.pop()) {
            self.queue.destroyNode(cursor.?, self.allocator);
        }

        cursor = self.nodes.pop();
        while (cursor != null) : (cursor = self.queue.pop()) {
            self.nodes.destroyNode(cursor.?, self.allocator);
        }
    }

    fn process(self: *Self) !void {
        var maybe_front = self.queue.popFirst();
        iterate: while (maybe_front != null) : (maybe_front = self.queue.popFirst()) {
            const front = maybe_front.?.data;

            // destroy if it already exists
            var cursor = self.nodes.first;
            while (cursor != null) : (cursor = cursor.?.next) {
                const node = cursor.?.data;
                if (std.mem.eql(u8, front.base_path, node.base_path) and
                    std.mem.eql(u8, front.version, node.version))
                {
                    self.queue.destroyNode(maybe_front.?, self.allocator);
                    continue :iterate;
                }
            }

            // compile zkg_runner
            const result = try front.zkg_runner();
            switch (result.term) {
                .Exited => |val| {
                    if (val != 0) {
                        std.debug.warn("{}", .{result.stderr});
                        return error.BadExit;
                    }
                },
                .Signal => |signal| {
                    std.debug.warn("got signal: {}\n", .{signal});
                    return error.Signal;
                },
                .Stopped => |why| {
                    std.debug.warn("stopped: {}\n", .{why});
                    return error.Stopped;
                },
                .Unknown => |val| {
                    std.debug.warn("unknown: {}\n", .{val});
                    return error.Unkown;
                },
            }

            std.debug.warn("{}\n", .{result});
            try self.results.append(result);

            var reader = std.io.fixedBufferStream(result.stdout).reader();

            std.debug.warn("fetching dependencies for {} {}\n", .{ front.base_path, front.version });
            var buf: [4096]u8 = undefined;
            var line = try reader.readUntilDelimiterOrEof(&buf, '\n');
            while (line != null) : (line = try reader.readUntilDelimiterOrEof(&buf, '\n')) {
                std.debug.warn("{}\n", .{line});
                // if not in nodes
                // set up edges
                // set depth to current + 1

                // else if it is in nodes and its depth is less than front
                // increase depth of node (in node list) to depth + 1
                // destroy dep

                // append to queue
            }

            self.nodes.append(maybe_front.?);
            try self.validate();
        }
    }

    /// Naive check for circular dependencies
    fn validate(self: *Self) !void {
        var cursor = self.nodes.first;
        while (cursor != null) : (cursor = cursor.?.next) {
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
        allocator: *Allocator,
        dependencies: ArrayList(DependencyEdge),
        dependents: ArrayList(DependentEdge),

        base_path: []const u8,
        version: []const u8,
        depth: u32,

        fn init(allocator: *Allocator, base_path: []const u8, version: []const u8, depth: u32) !Node {
            return Node{
                .allocator = allocator,
                .dependencies = ArrayList(DependencyEdge).init(allocator),
                .dependents = ArrayList(DependentEdge).init(allocator),
                .base_path = base_path,
                .version = version,
                .depth = depth,
            };
        }

        fn zkg_runner(self: *const Node) !ExecResult {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();

            const allocator = &arena.allocator;

            var build_buf: [std.os.PATH_MAX]u8 = undefined;
            const build_dir = try std.os.getcwd(&build_buf);
            const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ build_dir, "zig-cache" });

            const lib_dir = if (os.getenv("ZKG_LIB")) |dir| dir else "/usr/lib/zig/zkg";
            const runner_path = try std.fs.path.join(allocator, &[_][]const u8{ lib_dir, "zkg_runner.zig" });
            const zkg_path = try std.fs.path.join(allocator, &[_][]const u8{ lib_dir, "zkg.zig" });

            const builder = try Builder.create(allocator, "zig", build_dir, cache_dir);
            defer builder.destroy();

            builder.resolveInstallPrefix();
            std.debug.warn("install dir: {}\n", .{builder.install_prefix});

            // normal build script
            const target = builder.standardTargetOptions(.{});
            const mode = builder.standardReleaseOptions();

            const exe = builder.addExecutable("zkg_runner", runner_path);
            exe.setTarget(target);
            exe.setBuildMode(mode);
            exe.linkSystemLibrary("git2");
            exe.linkSystemLibrary("c");
            exe.addPackage(std.build.Pkg{
                .name = "zkg",
                .path = zkg_path,
            });
            exe.addIncludeDir(lib_dir);
            exe.addIncludeDir(build_dir);
            exe.install();

            try builder.make(&[_][]const u8{});
            return std.ChildProcess.exec(.{
                .allocator = self.allocator,
                .argv = &[_][]const u8{"zig-cache/bin/zkg_runner"},
            });
        }
    };
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var dep_graph = try DependencyGraph.init(allocator, ".");
    defer dep_graph.deinit();

    try dep_graph.process();
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

    for (dep_graph.nodes.first.?.data.dependencies.span()) |*dep| {
        try recursive_print(file_stream, dep, 1);
    }

    try file_stream.writeAll("};\n");
}

fn indent(stream: OutStream, n: usize) !void {
    try stream.writeByteNTimes(' ', n * 4);
}

fn recursive_print(stream: std.fs.File.OutStream, edge: *DependencyGraph.DependencyEdge, depth: usize) anyerror!void {
    try indent(stream, depth);
    try stream.print("Pkg{{\n", .{});
    try indent(stream, depth + 1);
    try stream.print(".name = \"{}\",\n", .{"NAME"});
    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{"PATH"});

    if (edge.node.dependencies.items.len > 0) {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = &[_]Pkg{{\n", .{});

        for (edge.node.dependencies.span()) |*dep| {
            try recursive_print(stream, dep, depth + 2);
        }
    } else {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = null,\n", .{});
    }

    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{"PATH"});
}
