const std = @import("std");
const os = std.os;
const debug = std.debug;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const OutStream = std.fs.File.OutStream;
const ChildProcess = std.ChildProcess;
const ExecResult = std.ChildProcess.ExecResult;
const Builder = std.build.Builder;

const DependencyGraph = struct {
    allocator: *Allocator,
    queue_start: usize,
    nodes: std.ArrayList(Node),
    results: ArrayList(ExecResult),

    const Self = @This();

    /// Create DependencyGraph given a root path
    fn init(allocator: *Allocator, path: []const u8) !DependencyGraph {
        var ret = DependencyGraph{
            .allocator = allocator,
            .queue_start = 0,
            .nodes = ArrayList(Node).init(allocator),
            .results = ArrayList(ExecResult).init(allocator),
        };

        // TODO: get cwd of process
        try ret.nodes.append(try Node.init(allocator, ".", 0));
        return ret;
    }

    fn deinit(self: *Self) void {
        self.nodes.deinit();

        for (self.results.span()) |result| {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
    }

    fn process(self: *Self) !void {
        while (self.queue_start < self.nodes.items.len) : (self.queue_start += 1) {
            var front = &self.nodes.items[self.queue_start];
            const result = try front.zkg_runner();
            switch (result.term) {
                .Exited => |val| {
                    if (val != 0) {
                        debug.print("{}", .{result.stderr});
                        return error.BadExit;
                    }
                },
                .Signal => |signal| {
                    debug.print("got signal: {}\n", .{signal});
                    return error.Signal;
                },
                .Stopped => |why| {
                    debug.print("stopped: {}\n", .{why});
                    return error.Stopped;
                },
                .Unknown => |val| {
                    debug.print("unknown: {}\n", .{val});
                    return error.Unkown;
                },
            }

            try self.results.append(result);
            var it_line = std.mem.tokenize(result.stdout, "\n");
            while (it_line.next()) |line| {
                var name: []const u8 = undefined;
                var path: []const u8 = undefined;
                var root: []const u8 = undefined;

                var it = std.mem.tokenize(line, " ");
                var i: i32 = 0;

                while (it.next()) |field| {
                    switch (i) {
                        0 => name = field,
                        1 => path = field,
                        2 => root = field,
                        else => break,
                    }

                    i += 1;
                }

                if (i != 3) {
                    return error.IssueWithParsing;
                }

                var found = for (self.nodes.items) |*node| {
                    if (std.mem.eql(u8, path, node.base_path))
                        break node;
                } else null;

                if (found) |node| {
                    try front.connect_dependency(node, name, root);
                } else {
                    try self.nodes.append(try Node.init(self.allocator, path, front.depth + 1));
                    try front.connect_dependency(&self.nodes.items[self.nodes.items.len - 1], name, root);
                }

                try self.validate();
            }
        }
    }

    /// Naive check for circular dependencies
    fn validate(self: *Self) !void {
        for (self.nodes.items) |*node| {
            for (node.dependencies.span()) |dep| {
                if (dep.node.depth <= node.depth) {
                    return error.CyclicalDependency;
                }
            }

            for (node.dependents.span()) |dep| {
                if (dep.depth >= node.depth) {
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
        dependents: ArrayList(*Node),
        base_path: []const u8,
        depth: u32,

        fn init(allocator: *Allocator, base_path: []const u8, depth: u32) !Node {
            return Node{
                .allocator = allocator,
                .dependencies = ArrayList(DependencyEdge).init(allocator),
                .dependents = ArrayList(*Node).init(allocator),
                .base_path = base_path,
                .depth = depth,
            };
        }

        fn connect_dependency(self: *Node, dep: *Node, alias: []const u8, root: []const u8) !void {
            if (self == dep)
                return error.CircularDependency;

            if (dep.depth <= self.depth)
                dep.depth = self.depth + 1;

            try self.dependencies.append(DependencyEdge{
                .node = dep,
                .alias = alias,
                .root = root,
            });
            try dep.dependents.append(self);
        }

        fn zkg_runner(self: *const Node) !ExecResult {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const imports_file = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ self.base_path, "imports.zig" },
            );
            defer self.allocator.free(imports_file);

            // if there is no imports.zig file then we don't need to run the
            // zkg_runner
            os.access(imports_file, 0) catch |err| {
                if (err == error.FileNotFound) {
                    return ExecResult{
                        .term = ChildProcess.Term{ .Exited = 0 },
                        .stdout = "",
                        .stderr = "",
                    };
                }

                return err;
            };

            const cache_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ self.base_path, "zig-cache" });
            const lib_dir = if (os.getenv("ZKG_LIB")) |dir| dir else "/usr/lib/zig/zkg";
            const source = try std.fs.path.join(self.allocator, &[_][]const u8{ lib_dir, "zkg_runner.zig" });
            const zkg_path = try std.fs.path.join(self.allocator, &[_][]const u8{ lib_dir, "zkg.zig" });

            const builder = try Builder.create(self.allocator, "zig", self.base_path, cache_dir);
            defer builder.destroy();

            builder.resolveInstallPrefix();

            // normal build script
            const target = builder.standardTargetOptions(.{});
            const mode = builder.standardReleaseOptions();

            const exe = builder.addExecutable("zkg_runner", source);
            const zkg = std.build.Pkg{
                .name = "zkg",
                .path = zkg_path,
            };

            exe.setTarget(target);
            exe.setBuildMode(mode);
            exe.linkSystemLibrary("git2");
            exe.linkSystemLibrary("c");

            exe.addPackage(zkg);
            exe.addPackage(std.build.Pkg{
                .name = "imports",
                .path = imports_file,
                .dependencies = &[_]std.build.Pkg{zkg},
            });

            exe.addIncludeDir(lib_dir);
            exe.addIncludeDir(self.base_path);
            exe.install();

            try builder.make(&[_][]const u8{});
            defer std.fs.cwd().deleteFile("zig-cache/bin/zkg_runner") catch {};

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
    try dep_graph.process();

    var cache_dir = std.fs.Dir{ .fd = try os.open("zig-cache", os.O_DIRECTORY, 0) };
    defer cache_dir.close();

    const gen_file = try cache_dir.createFile("packages.zig", std.fs.File.CreateFlags{
        .truncate = true,
    });
    errdefer cache_dir.deleteFile("packages.zig") catch {};
    defer gen_file.close();

    const file_stream = gen_file.outStream();
    try file_stream.writeAll(
        \\const std = @import("std");
        \\const Pkg = std.build.Pkg;
        \\
        \\pub const list = [_]Pkg{
        \\
    );

    for (dep_graph.nodes.items[0].dependencies.items) |*dep| {
        try recursive_print(allocator, file_stream, dep, 1);
    }

    try file_stream.writeAll("};\n");
}

fn indent(stream: OutStream, n: usize) !void {
    try stream.writeByteNTimes(' ', n * 4);
}

fn recursive_print(
    allocator: *Allocator,
    stream: std.fs.File.OutStream,
    edge: *DependencyGraph.DependencyEdge,
    depth: usize,
) anyerror!void {
    const path = try std.fs.path.join(allocator, &[_][]const u8{
        edge.node.base_path,
        edge.root,
    });
    defer allocator.free(path);

    try indent(stream, depth);
    try stream.print("Pkg{{\n", .{});
    try indent(stream, depth + 1);
    try stream.print(".name = \"{}\",\n", .{edge.alias});
    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{path});

    if (edge.node.dependencies.items.len > 0) {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = &[_]Pkg{{\n", .{});

        for (edge.node.dependencies.items) |*dep| {
            try recursive_print(allocator, stream, dep, depth + 2);
        }

        try indent(stream, depth + 1);
        try stream.print("}},\n", .{});
    } else {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = null,\n", .{});
    }

    try indent(stream, depth);
    try stream.print("}},\n", .{});
}
