const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const http = @import("http");
const net = @import("net");
const ssl = @import("ssl");
const Uri = @import("uri").Uri;
const Manifest = @import("manifest.zig");
const Import = @import("import.zig").Import;

const os = std.os;
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const json = std.json;
const fmt = std.fmt;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const OutStream = std.fs.File.OutStream;

const default_remote = "https://zpm.random-projects.net/api";
const imports_zzz = "imports.zzz";

const ziglibs_pem = @embedFile("ziglibs.pem");

const DependencyGraph = struct {
    allocator: *Allocator,
    cache: []const u8,
    queue_start: usize,
    nodes: std.ArrayList(Node),
    manifests: ArrayList(Manifest),

    const Self = @This();

    /// Create DependencyGraph given a root path
    fn init(allocator: *Allocator, path: []const u8, cache: []const u8) !DependencyGraph {
        var ret = DependencyGraph{
            .allocator = allocator,
            .cache = cache,
            .queue_start = 0,
            .nodes = ArrayList(Node).init(allocator),
            .manifests = ArrayList(Manifest).init(allocator),
        };

        // TODO: get cwd of process
        try ret.nodes.append(try Node.init(allocator, "", 0));
        return ret;
    }

    fn deinit(self: *Self) void {
        self.nodes.deinit();

        for (self.manifests.items) |manifest| {
            manifest.deinit();
        }
    }

    fn process(self: *Self) !void {
        while (self.queue_start < self.nodes.items.len) : (self.queue_start += 1) {
            var front = &self.nodes.items[self.queue_start];
            const import_path = if (front.base_path.len == 0)
                imports_zzz
            else
                try std.fs.path.join(self.allocator, &[_][]const u8{
                    front.base_path,
                    imports_zzz,
                });
            defer if (front.base_path.len != 0) self.allocator.free(import_path);

            const file = std.fs.cwd().openFile(import_path, .{ .read = true }) catch |err| {
                if (err == error.FileNotFound)
                    continue
                else
                    return err;
            };
            try self.manifests.append(try Manifest.init(self.allocator, file));

            var manifest = &self.manifests.items[self.manifests.items.len - 1];
            for (manifest.*.deps.items) |dep| {
                const path = try dep.path(self.allocator, self.cache);
                defer self.allocator.free(path);

                for (self.nodes.items) |*node| {
                    if (mem.eql(u8, path, node.base_path)) {
                        try front.connect_dependency(node, dep.name, dep.root);
                        break;
                    }
                } else {
                    try dep.fetch(self.allocator, self.cache);
                    try self.nodes.append(try Node.init(self.allocator, path, front.depth + 1));
                    try front.connect_dependency(
                        &self.nodes.items[self.nodes.items.len - 1],
                        dep.name,
                        dep.root,
                    );
                }

                try self.validate();
            }
        }
    }

    /// Naive check for circular dependencies
    fn validate(self: *Self) !void {
        for (self.nodes.items) |*node| {
            for (node.dependencies.items) |dep| {
                if (dep.node.depth <= node.depth) {
                    return error.CyclicalDependency;
                }
            }

            for (node.dependents.items) |dep| {
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
                .base_path = try allocator.dupe(u8, base_path),
                .depth = depth,
            };
        }

        fn deinit(self: *Node) void {
            self.allocator(base_path);
            self.dependents.deinit();
            self.dependencies.deinit();
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
    };
};

fn indent(stream: OutStream, n: usize) !void {
    try stream.writeByteNTimes(' ', n * 4);
}

fn recusivePrint(
    allocator: *Allocator,
    stream: fs.File.OutStream,
    edge: *DependencyGraph.DependencyEdge,
    depth: usize,
) anyerror!void {
    const root_file = try std.mem.replaceOwned(u8, allocator, edge.root, "/", &[_]u8{fs.path.sep});
    defer allocator.free(root_file);

    var path = try fs.path.join(allocator, &[_][]const u8{
        edge.node.base_path,
        root_file,
    });
    defer allocator.free(path);

    if (fs.path.sep == '\\') {
        const tmp = try std.mem.replaceOwned(u8, allocator, path, "\\", "\\\\");
        allocator.free(path);
        path = tmp;
    }

    try indent(stream, depth);
    if (depth == 1) {
        try stream.print(".{} = .{{\n", .{edge.alias});
    } else {
        try stream.print(".{{\n", .{});
    }

    try indent(stream, depth + 1);
    try stream.print(".name = \"{}\",\n", .{edge.alias});
    try indent(stream, depth + 1);
    try stream.print(".path = \"{}\",\n", .{path});
    if (edge.node.dependencies.items.len > 0) {
        try indent(stream, depth + 1);
        try stream.print(".dependencies = .{{\n", .{});

        for (edge.node.dependencies.items) |*dep| {
            try recusivePrint(allocator, stream, dep, depth + 2);
        }

        try indent(stream, depth + 1);
        try stream.print("}},\n", .{});
    }

    try indent(stream, depth);
    try stream.print("}},\n", .{});
}

pub fn fetch(cache_path: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    fs.cwd().access(imports_zzz, .{ .read = true, .write = true }) catch |err| {
        if (err == error.FileNotFound) {
            _ = try std.io.getStdErr().writer().write("imports.zzz does not exist\n");
        }

        return err;
    };

    var dep_graph = try DependencyGraph.init(allocator, ".", "zig-deps");
    try dep_graph.process();

    const gen_file = try std.fs.cwd().createFile("deps.zig", fs.File.CreateFlags{
        .truncate = true,
    });
    errdefer std.fs.cwd().deleteFile("deps.zig") catch {};
    defer gen_file.close();

    const file_stream = gen_file.outStream();
    try file_stream.writeAll(
        \\pub const pkgs = .{
        \\
    );

    for (dep_graph.nodes.items[0].dependencies.items) |*dep| {
        try recusivePrint(allocator, file_stream, dep, 1);
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

fn httpRequest(
    allocator: *Allocator,
    hostname: [:0]const u8,
    port: u16,
    params: []const u8,
) !std.ArrayList(u8) {
    var socket = try net.connectToHost(allocator, hostname, port, .tcp);
    defer socket.close();

    var buf: [mem.page_size]u8 = undefined;
    var http_client = http.base.client.create(
        &buf,
        socket.reader(),
        socket.writer(),
    );

    try http_client.writeStatusLine("GET", params);
    try http_client.writeHeaderValue("Accept", "application/json");
    try http_client.writeHeaderValue("Host", hostname);
    try http_client.writeHeaderValue("Agent", "zkg");
    try http_client.finishHeaders();

    return readHttpBody(allocator, &http_client);
}

fn httpsRequest(
    allocator: *Allocator,
    hostname: [:0]const u8,
    port: u16,
    params: []const u8,
) !std.ArrayList(u8) {
    var trust_anchor = ssl.TrustAnchorCollection.init(allocator);
    defer trust_anchor.deinit();

    switch (builtin.os.tag) {
        .linux => pem: {
            const file = std.fs.openFileAbsolute("/etc/ssl/cert.pem", .{ .read = true }) catch |err| {
                if (err == error.FileNotFound) {
                    try trust_anchor.appendFromPEM(ziglibs_pem);
                    break :pem;
                } else return err;
            };
            defer file.close();

            const certs = try file.readToEndAlloc(allocator, 500000);
            defer allocator.free(certs);

            try trust_anchor.appendFromPEM(certs);
        },
        else => {
            try trust_anchor.appendFromPEM(ziglibs_pem);
        },
    }

    var x509 = ssl.x509.Minimal.init(trust_anchor);
    var ssl_client = ssl.Client.init(x509.getEngine());
    ssl_client.relocate();
    try ssl_client.reset(hostname, false);

    var socket = try net.connectToHost(allocator, hostname, port, .tcp);
    defer socket.close();

    var socket_reader = socket.reader();
    var socket_writer = socket.writer();

    var ssl_socket = ssl.initStream(
        ssl_client.getEngine(),
        &socket_reader,
        &socket_writer,
    );
    defer ssl_socket.close() catch {};

    var buf: [mem.page_size]u8 = undefined;
    var http_client = http.base.client.create(
        &buf,
        ssl_socket.inStream(),
        ssl_socket.outStream(),
    );

    try http_client.writeStatusLine("GET", params);
    try http_client.writeHeaderValue("Accept", "application/json");
    try http_client.writeHeaderValue("Host", hostname);
    try http_client.writeHeaderValue("Agent", "zkg");
    try http_client.finishHeaders();
    try ssl_socket.flush();

    return readHttpBody(allocator, &http_client);
}

fn readHttpBody(allocator: *mem.Allocator, client: anytype) !std.ArrayList(u8) {
    var body = std.ArrayList(u8).init(allocator);
    errdefer body.deinit();

    while (try client.next()) |event| {
        switch (event) {
            .status => |status| {
                if (status.code != 200) {
                    try std.io.getStdErr().writer().print("got HTTP {} return code\n", .{status.code});
                    return error.BadStatusCode;
                }
            },
            .head_done => break,
            .header, .end, .skip => {},
            .payload => unreachable,
        }
    }

    try client.reader().readAllArrayList(&body, 4 * 1024 * 1024);

    return body;
}

pub const SearchParams = union(enum) {
    all: void,
    name: []const u8,
    tag: []const u8,
    author: []const u8,
};

const Params = union(enum) {
    packages: SearchParams,
    tags: void,

    fn append_param(buf: []u8, key: []const u8, value: []const u8) ![]u8 {
        return try fmt.bufPrint(buf, "?{}={}", .{ key, value });
    }

    fn print(self: Params, buf: []u8, uri: Uri) ![]const u8 {
        var n = (try fmt.bufPrint(buf, "{}", .{uri.path})).len;

        if (n == 0 or buf[n - 1] != '/') {
            n += (try fmt.bufPrint(buf[n..], "/", .{})).len;
        }

        switch (self) {
            .packages => |search_params| {
                n += (try fmt.bufPrint(buf[n..], "packages", .{})).len;
                switch (search_params) {
                    .name => |name| {
                        n += (try append_param(buf[n..], "name", name)).len;
                    },
                    .tag => |tag| {
                        n += (try append_param(buf[n..], "tags", tag)).len;
                    },
                    .author => |author| {
                        n += (try append_param(buf[n..], "author", author)).len;
                    },
                    .all => {},
                }
            },
            .tags => {
                n += (try fmt.bufPrint(buf[n..], "tags", .{})).len;
            },
        }

        return buf[0..n];
    }
};

fn query(
    allocator: *mem.Allocator,
    remote: []const u8,
    params: Params,
) !std.ArrayList(u8) {
    const uri = try Uri.parse(remote, false);
    const protocol: Protocol = if (mem.eql(u8, uri.scheme, "http"))
        .http
    else if (mem.eql(u8, uri.scheme, "https"))
        .https
    else if (mem.eql(u8, uri.scheme, ""))
        return error.MissingProtocol
    else
        return error.UnsupportedProtocol;

    const port: u16 = if (uri.port) |port| port else protocol.to_port();
    const hostnameZ = try mem.dupeZ(allocator, u8, uri.host.name);
    defer allocator.free(hostnameZ);

    const question: []const u8 = "?";
    const none: []const u8 = "";
    var params_buf: [2048]u8 = undefined;
    const params_str = try params.print(&params_buf, uri);

    return switch (protocol) {
        .http => httpRequest(allocator, hostnameZ, port, params_str),
        .https => httpsRequest(allocator, hostnameZ, port, params_str),
    };
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
            .root_file = switch (obj.Object.get("root_file").?) {
                .String => |str| str,
                .Null => "/src/main.zig",
                else => unreachable,
            },
            .author = obj.Object.get("author").?.String,
            .description = obj.Object.get("description").?.String,
        };
    }
};

const Column = struct {
    str: []const u8,
    width: usize,
};

fn printColumns(writer: anytype, columns: []const Column, last: []const u8) !void {
    for (columns) |column| {
        try writer.print("{}", .{column.str});
        if (column.str.len < column.width) {
            try writer.writeByteNTimes(' ', column.width - column.str.len);
        }
    }

    try writer.print("{}\n", .{last});
}

pub fn search(
    allocator: *mem.Allocator,
    params: SearchParams,
    print_json: bool,
    remote_opt: ?[]const u8,
) !void {
    const response = try query(allocator, remote_opt orelse default_remote, .{
        .packages = params,
    });
    defer response.deinit();

    if (print_json) {
        _ = try std.io.getStdOut().writer().write(response.items);
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

    try printColumns(
        std.io.getStdErr().writer(),
        &[_]Column{
            .{ .str = name_title, .width = name_width },
            .{ .str = author_title, .width = author_width },
        },
        desc_title,
    );

    for (entries.items) |item| {
        try printColumns(
            std.io.getStdOut().writer(),
            &[_]Column{
                .{ .str = item.name, .width = name_width },
                .{ .str = item.author, .width = author_width },
            },
            item.description,
        );
    }
}

const Tag = struct {
    name: []const u8,
    description: []const u8,

    fn from_json(obj: json.Value) !Tag {
        if (obj != .Object) return error.NotObject;

        return Tag{
            .name = obj.Object.get("name").?.String,
            .description = obj.Object.get("description").?.String,
        };
    }
};

pub fn tags(allocator: *mem.Allocator, remote_opt: ?[]const u8) !void {
    const response = try query(allocator, remote_opt orelse default_remote, .{
        .tags = {},
    });
    defer response.deinit();

    var parser = json.Parser.init(allocator, false);
    defer parser.deinit();

    const tree = try parser.parse(response.items);
    const root = tree.root;

    if (root != .Array) {
        return error.ResponseType;
    }

    var entries = std.ArrayList(Tag).init(allocator);
    defer entries.deinit();

    for (root.Array.items) |item| {
        try entries.append(try Tag.from_json(item));
    }

    const name_title = "TAG";
    const desc_title = "DESCRIPTION";

    var name_width: usize = 0;
    for (entries.items) |item| {
        name_width = std.math.max(name_width, item.name.len);
    }

    name_width = std.math.max(name_width, name_title.len) + 2;

    try printColumns(
        std.io.getStdErr().writer(),
        &[_]Column{.{ .str = name_title, .width = name_width }},
        desc_title,
    );

    for (entries.items) |item| {
        try printColumns(
            std.io.getStdOut().writer(),
            &[_]Column{.{ .str = item.name, .width = name_width }},
            item.description,
        );
    }
}

pub fn add(
    allocator: *mem.Allocator,
    name: []const u8,
    alias_opt: ?[]const u8,
    remote_opt: ?[]const u8,
) !void {
    const alias = alias_opt orelse name;

    const file = try std.fs.cwd().createFile(imports_zzz, .{
        .read = true,
        .exclusive = false,
        .truncate = false,
    });
    defer file.close();

    var manifest = try Manifest.init(allocator, file);
    defer manifest.deinit();

    const response = try query(allocator, remote_opt orelse default_remote, .{
        .packages = .{ .name = name },
    });
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
    var import = Import{
        .name = alias,
        .root = entry.root_file,
        .src = try Import.urlToSource(entry.git),
    };

    const head = try import.getBranchHead(allocator);
    defer if (head) |h| allocator.free(h);
    if (head) |commit| {
        switch (import.src) {
            .github => {
                import.src.github.ref = commit;
            },
            else => unreachable,
        }
    }

    try manifest.addImport(import);
    try manifest.commit();
}

pub fn remove(allocator: *Allocator, name: []const u8) !void {
    const file = try std.fs.cwd().openFile(imports_zzz, .{ .read = true, .write = true });
    defer file.close();

    var manifest = try Manifest.init(allocator, file);
    defer manifest.deinit();

    try manifest.removeImport(name);
    try manifest.commit();
}
