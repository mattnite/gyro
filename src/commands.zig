const std = @import("std");
const clap = @import("clap");
const http = @import("http");
const net = @import("net");
const ssl = @import("ssl");
const Uri = @import("uri").Uri;
const CertificateValidator = @import("certificate_validator.zig");

const os = std.os;
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const json = std.json;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const OutStream = std.fs.File.OutStream;
const ChildProcess = std.ChildProcess;
const ExecResult = std.ChildProcess.ExecResult;
const Builder = std.build.Builder;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const default_remote = "https://zpm.random-projects.net/api";
const imports_zig = "imports.zig";

const DependencyGraph = struct {
    allocator: *Allocator,
    cache: []const u8,
    queue_start: usize,
    nodes: std.ArrayList(Node),
    results: ArrayList(ExecResult),

    const Self = @This();

    /// Create DependencyGraph given a root path
    fn init(allocator: *Allocator, path: []const u8, cache: []const u8) !DependencyGraph {
        var ret = DependencyGraph{
            .allocator = allocator,
            .cache = cache,
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
            const result = try front.zkg_runner(self.cache);
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
            var it_line = mem.tokenize(result.stdout, "\n");
            while (it_line.next()) |line| {
                var name: []const u8 = undefined;
                var path: []const u8 = undefined;
                var root: []const u8 = undefined;

                var it = mem.tokenize(line, " ");
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
                    if (mem.eql(u8, path, node.base_path))
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

        fn zkg_runner(self: *const Node, cache: []const u8) !ExecResult {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const imports_file = try fs.path.join(
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

            const cache_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.base_path, cache });
            const lib_dir = if (os.getenv("ZKG_LIB")) |dir| dir else "/usr/lib/zig/zkg";
            const source = try fs.path.join(self.allocator, &[_][]const u8{ lib_dir, "zkg_runner.zig" });
            const zkg_path = try fs.path.join(self.allocator, &[_][]const u8{ lib_dir, "zkg.zig" });

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
            const runner_exe = try fs.path.join(self.allocator, &[_][]const u8{ cache, "bin", "zkg_runner" });
            defer {
                fs.cwd().deleteFile(runner_exe) catch {};
                self.allocator.free(runner_exe);
            }

            return std.ChildProcess.exec(.{
                .allocator = self.allocator,
                .argv = &[_][]const u8{runner_exe},
            });
        }
    };
};

fn indent(stream: OutStream, n: usize) !void {
    try stream.writeByteNTimes(' ', n * 4);
}

fn recursive_print(
    allocator: *Allocator,
    stream: fs.File.OutStream,
    edge: *DependencyGraph.DependencyEdge,
    depth: usize,
) anyerror!void {
    const path = try fs.path.join(allocator, &[_][]const u8{
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

pub fn fetch(cache_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    fs.cwd().access(imports_zig, .{ .read = true, .write = true }) catch |err| {
        if (err == error.FileNotFound) {
            _ = try stderr.write("imports.zig has not been initialized in this directory\n");
        }

        return err;
    };

    const cache = cache_path orelse "zig-cache";
    var dep_graph = try DependencyGraph.init(allocator, ".", cache);
    try dep_graph.process();

    var cache_dir = fs.Dir{ .fd = try os.open(cache, os.O_DIRECTORY, 0) };
    defer cache_dir.close();

    const gen_file = try cache_dir.createFile("packages.zig", fs.File.CreateFlags{
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

const Protocol = enum {
    http,
    https,

    pub fn to_port(self: Protocol) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }
};

fn query(
    allocator: *mem.Allocator,
    remote: []const u8,
    name: ?[]const u8,
    tag: ?[]const u8,
) !std.ArrayList(u8) {
    if (name != null and tag != null) return error.OnlyNameOrTag;

    var uri_buf: [2048]u8 = undefined;
    const uri_str = if (name != null)
        try std.fmt.bufPrint(&uri_buf, "{}?{}={}", .{ remote, "name", name.? })
    else if (tag != null)
        try std.fmt.bufPrint(&uri_buf, "{}?{}={}", .{ remote, "tags", tag.? })
    else
        try std.fmt.bufPrint(&uri_buf, "{}", .{remote});

    const uri = try Uri.parse(uri_str, false);
    const protocol: Protocol = if (mem.eql(u8, uri.scheme, "http"))
        .http
    else if (mem.eql(u8, uri.scheme, "https"))
        .https
    else if (mem.eql(u8, uri.scheme, ""))
        return error.MissingProtocol
    else
        return error.UnsupportedProtocol;

    const port: u16 = if (uri.port) |port| port else protocol.to_port();
    var socket = try net.connectToHost(allocator, uri.host.name, port, .tcp);
    defer socket.close();

    // http ssl setup
    var x509 = CertificateValidator.init(allocator);
    defer x509.deinit();

    var ssl_client = ssl.Client.init(x509.getEngine());
    ssl_client.relocate();

    const hostnameZ = try mem.dupeZ(allocator, u8, uri.host.name);
    defer allocator.free(hostnameZ);

    try ssl_client.reset(hostnameZ, false);

    var socket_reader = socket.reader();
    var socket_writer = socket.writer();

    var buf: [mem.page_size]u8 = undefined;

    var ssl_socket = ssl.initStream(
        ssl_client.getEngine(),
        &socket_reader,
        &socket_writer,
    );
    defer ssl_socket.close() catch {};

    var http_client = http.base.Client.create(
        &buf,
        ssl_socket.inStream(),
        ssl_socket.outStream(),
    );

    const question: []const u8 = "?";
    const none: []const u8 = "";
    var params_buf: [2048]u8 = undefined;
    var params = try std.fmt.bufPrint(&params_buf, "{}", .{
        if (uri.path.len > 0) uri.path else "/",
    });

    if (uri.query.len > 0) {
        params = params_buf[0 .. params.len +
            (try std.fmt.bufPrint(params_buf[params.len..], "?{}", .{uri.query})).len];
    }

    try http_client.writeHead("GET", params);
    try http_client.writeHeaderValue("Accept", "application/json");
    try http_client.writeHeaderValue("Host", uri.host.name);
    try http_client.writeHeadComplete();

    var response_body = std.ArrayList(u8).init(allocator);
    errdefer response_body.deinit();

    while (try http_client.readEvent()) |event| {
        switch (event) {
            .status => |status| {
                if (status.code != 200) {
                    return error.BadStatusCode;
                }
            },
            .invalid => |invalid| {
                std.debug.print("{}\n", .{invalid.message});
                return error.Invalid;
            },
            .chunk => |chunk| {
                try response_body.appendSlice(chunk.data);
                if (chunk.final) break;
            },
            .closed => return error.ClosedAbruptly,
            .header, .head_complete, .end => {},
        }
    }

    return response_body;
}

const Entry = struct {
    name: []const u8,
    git: []const u8,
    root_file: []const u8,
    author: []const u8,
    description: []const u8,

    pub fn from_json(obj: json.Value) !Entry {
        if (obj != .Object) return error.NotObject;

        return Entry{
            .name = obj.Object.get("name").?.String,
            .git = obj.Object.get("git").?.String,
            .root_file = obj.Object.get("root_file").?.String,
            .author = obj.Object.get("author").?.String,
            .description = obj.Object.get("description").?.String,
        };
    }
};

const Column = struct {
    str: []const u8,
    width: usize,
};

fn print_columns(writer: anytype, name: Column, author: Column, description: []const u8) !void {
    try writer.print("{}", .{name.str});
    if (name.str.len < name.width) {
        try writer.writeByteNTimes(' ', name.width - name.str.len);
    }

    try writer.print("{}", .{author.str});
    if (author.str.len < author.width) {
        try writer.writeByteNTimes(' ', author.width - author.str.len);
    }

    try writer.print("{}\n", .{description});
}

pub fn search(
    allocator: *mem.Allocator,
    name: ?[]const u8,
    tag: ?[]const u8,
    print_json: bool,
    remote_opt: ?[]const u8,
) !void {
    const response = try query(allocator, remote_opt orelse default_remote, name, tag);
    defer response.deinit();

    if (print_json) {
        _ = try stdout.write(response.items);
        return;
    }

    var parser = json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response.items);
    const root = tree.root;

    var entries = std.ArrayList(Entry).init(allocator);
    defer entries.deinit();

    if (root != .Array) {
        return error.ResponseType;
    }

    for (root.Array.items) |item| {
        try entries.append(try Entry.from_json(item));
    }

    // column sizes
    var name_width: usize = 0;
    var author_width: usize = 0;
    for (entries.items) |item| {
        name_width = std.math.max(name_width, item.name.len);
        author_width = std.math.max(author_width, item.author.len);
    }

    const name_title = "NAME";
    const author_title = "AUTHOR";
    const desc_title = "DESCRIPTION";

    name_width = std.math.max(name_width, name_title.len) + 2;
    author_width = std.math.max(author_width, author_title.len) + 2;

    try print_columns(
        stderr,
        .{ .str = "NAME", .width = name_width },
        .{ .str = "AUTHOR", .width = author_width },
        desc_title,
    );

    for (entries.items) |item| {
        try print_columns(
            stdout,
            .{ .str = item.name, .width = name_width },
            .{ .str = item.author, .width = author_width },
            item.description,
        );
    }
}

pub fn tags(allocator: *mem.Allocator, remote_opt: ?[]const u8) !void {
    const response = try query(allocator, remote_opt orelse default_remote, null, null);
    defer response.deinit();

    var parser = json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response.items);
    const root = tree.root;

    if (root != .Array) {
        return error.ResponseType;
    }

    // TODO: alphabetic printing
    var set = std.StringHashMap(void).init(allocator);
    defer set.deinit();

    for (root.Array.items) |entry| {
        for (entry.Object.get("tags").?.Array.items) |tag| {
            try set.put(tag.String, .{});
        }
    }

    var it = set.iterator();
    while (it.next()) |entry| {
        try stdout.print("{}\n", .{entry.key});
    }
}

pub fn init() !void {
    fs.cwd().access(imports_zig, .{ .read = true, .write = true }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try fs.cwd().writeFile(imports_zig, "const zkg = @import(\"zkg\");\n");
            },
            else => return err,
        }
    };
}

pub fn add(
    allocator: *mem.Allocator,
    name: []const u8,
    alias_opt: ?[]const u8,
    remote_opt: ?[]const u8,
) !void {
    const alias = alias_opt orelse name;
    const imports = fs.cwd().openFile(imports_zig, .{ .read = true, .write = true }) catch |err| {
        if (err == error.FileNotFound) {
            _ = try stderr.write("need to create an imports.zig file with 'zkg init'\n");
        }

        return err;
    };
    defer imports.close();

    const contents = try imports.readToEndAlloc(allocator, 0x2000);
    defer allocator.free(contents);

    var it = mem.tokenize(contents, ";");

    while (it.next()) |expr| {
        var tok_it = mem.tokenize(expr, "\n ");
        const public = tok_it.next() orelse continue;
        const constant = tok_it.next() orelse continue;

        if (!mem.eql(u8, public, "pub")) continue;
        if (!mem.eql(u8, constant, "const")) continue;

        const token = tok_it.next() orelse continue;
        if (mem.eql(u8, token, alias)) {
            try stderr.print("{} is already declared in imports.zig\n", .{alias});
            return error.AliasExists;
        }
    }

    const response = try query(allocator, remote_opt orelse default_remote, name, null);
    defer response.deinit();

    var parser = json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response.items);
    const root = tree.root;

    if (root != .Array) {
        return error.ResponseType;
    }

    if (root.Array.items.len == 0) {
        return error.NameMatch;
    } else if (root.Array.items.len != 1) {
        return error.Ambiguous;
    }

    const entry = try Entry.from_json(root.Array.items[0]);
    const writer = imports.writer();
    try writer.print(
        \\
        \\pub const {} = zkg.import.git(
        \\    "{}",
        \\    "master",
        \\    "{}",
        \\);
        \\
    , .{ alias, entry.git, entry.root_file });
}

pub fn remove(name: []const u8) !void {
    // search imports for declaration matching name, delete it
    return error.NotImplementedYetSry;
}
