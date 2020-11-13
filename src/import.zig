const std = @import("std");
const net = @import("net");
const ssl = @import("ssl");
const http = @import("http");
const Uri = @import("uri").Uri;
const tar = @import("tar.zig");
const zzz = @import("zzz");

const Allocator = std.mem.Allocator;
const gzipStream = std.compress.gzip.gzipStream;

pub const Import = struct {
    name: []const u8,
    root: []const u8,
    src: Source,
    integrity: ?Integrity = null,

    const Self = @This();
    const Hasher = std.crypto.hash.blake2.Blake2b128;

    const Source = union(enum) {
        github: Github,
        url: []const u8,

        const Github = struct {
            user: []const u8,
            repo: []const u8,
            ref: []const u8,
        };

        fn addToZNode(source: Source, root: *zzz.ZNode, tree: anytype) !void {
            if (@typeInfo(@TypeOf(tree)) != .Pointer) {
                @compileError("tree must be pointer");
            }

            switch (source) {
                .github => |github| {
                    var node = try tree.addNode(root, .{ .String = "github" });
                    _ = try tree.addNode(node, .{ .String = github.user });
                    _ = try tree.addNode(node, .{ .String = github.repo });
                    _ = try tree.addNode(node, .{ .String = github.ref });
                },
                .url => |url| {
                    var node = try tree.addNode(root, .{ .String = "url" });
                    _ = try tree.addNode(node, .{ .String = url });
                },
            }
        }

        fn fromZNode(node: *const zzz.ZNode) !Source {
            const key = try getZNodeString(node);
            return if (std.mem.eql(u8, "github", key)) blk: {
                var repo: ?[]const u8 = null;
                var user: ?[]const u8 = null;
                var ref: ?[]const u8 = null;

                var child = node.*.child;
                while (child) |elem| : (child = child.?.sibling) {
                    const gh_key = try getZNodeString(elem);

                    if (std.mem.eql(u8, "repo", gh_key)) {
                        repo = try getZNodeString(elem.child orelse return error.MissingRepo);
                    } else if (std.mem.eql(u8, "user", gh_key)) {
                        user = try getZNodeString(elem.child orelse return error.MissingUser);
                    } else if (std.mem.eql(u8, "ref", gh_key)) {
                        ref = try getZNodeString(elem.child orelse return error.MissingRef);
                    } else {
                        std.debug.print("unknown gh_key: {}\n", .{gh_key});
                        return error.UnknownKey;
                    }
                }

                break :blk Source{
                    .github = .{
                        .repo = repo orelse return error.MissingRepo,
                        .user = user orelse return error.MissingUser,
                        .ref = ref orelse return error.MissingRef,
                    },
                };
            } else if (std.mem.eql(u8, "url", key))
                Source{ .url = try getZNodeString(node.*.child orelse return error.MissingUrl) }
            else {
                std.debug.print("unknown key: {}\n", .{key});
                return error.UnknownKey;
            };
        }
    };

    const Integrity = union(enum) {
        sha256: []const u8,

        fn fromZNode(node: *const zzz.ZNode) !Integrity {
            const key = try getZNodeString(node);

            const hash_type = try getZNodeString(node.*.child orelse return error.MissingHash);
            const digest = try getZNodeString(node.*.child orelse return error.MissingDigest);

            return if (std.mem.eql(u8, "sha256", hash_type))
                Integrity{ .sha256 = digest }
            else
                error.UnknownHashType;
        }
    };

    fn getZNodeString(node: *const zzz.ZNode) ![]const u8 {
        return switch (node.value) {
            .String => |str| str,
            else => return error.NotAString,
        };
    }

    pub fn fromZNode(node: *const zzz.ZNode) !Import {
        const name = switch (node.value) {
            .String => |str| str,
            else => return error.MissingName,
        };

        var root_path: ?[]const u8 = null;
        var src: ?Source = null;
        var integrity: ?Integrity = null;

        var child = node.*.child;
        while (child) |elem| : (child = child.?.sibling) {
            const key = try getZNodeString(elem);

            if (std.mem.eql(u8, "root", key)) {
                root_path = try getZNodeString(elem);
            } else if (std.mem.eql(u8, "src", key)) {
                src = try Source.fromZNode(elem.child orelse return error.MissingSourceType);
            } else if (std.mem.eql(u8, "integrity", key)) {
                integrity = try Integrity.fromZNode(elem.child orelse return error.MissingHashType);
            } else {
                std.debug.print("unknown key: {}\n", .{key});
                return error.UnknownKey;
            }
        }

        return Import{
            .name = name,
            .root = root_path orelse "src/main.zig",
            .src = src orelse return error.MissingSource,
            .integrity = integrity,
        };
    }

    pub fn addToZNode(self: Self, root: *zzz.ZNode, tree: anytype) !void {
        if (@typeInfo(@TypeOf(tree)) != .Pointer) {
            @compileError("tree must be pointer");
        }

        const import = try tree.addNode(root, .{ .String = self.name });
        const root_path = try tree.addNode(import, .{ .String = "root" });
        _ = try tree.addNode(root_path, .{ .String = self.root });

        const src = try tree.addNode(import, .{ .String = "src" });
        try self.src.addToZNode(src, tree);

        if (self.integrity) |integrity| {
            const integ_node = try tree.addNode(import, .{ .String = "integrity" });
            switch (integrity) {
                .sha256 => |sha256| _ = try tree.addNode(integ_node, .{ .String = sha256 }),
            }
        }
    }

    pub fn urlToSource(url: []const u8) !Source {
        return Source{ .url = "" };
    }

    pub fn toUrl(self: Import, allocator: *Allocator) ![]const u8 {
        return switch (self.src) {
            .github => |github| try std.mem.join(allocator, "/", &[_][]const u8{
                "https://api.github.com/repos",
                github.user,
                github.repo,
                "tarball",
                github.ref,
            }),
            .url => |url| try allocator.dupe(u8, url),
        };
    }

    pub fn path(self: Self, allocator: *Allocator, base_path: []const u8) ![]const u8 {
        const digest = try self.hash();
        return std.fs.path.join(allocator, &[_][]const u8{ base_path, &digest });
    }

    pub fn hash(self: Self) ![Hasher.digest_length * 2]u8 {
        var tree = zzz.ZTree(1, 100){};
        var root = try tree.addNode(null, .Null);
        try self.src.addToZNode(root, &tree);

        var buf: [std.mem.page_size]u8 = undefined;
        var digest: [Hasher.digest_length]u8 = undefined;
        var ret: [Hasher.digest_length * 2]u8 = undefined;
        var fixed_buffer = std.io.fixedBufferStream(&buf);

        try root.stringify(fixed_buffer.writer());
        Hasher.hash(fixed_buffer.getWritten(), &digest, .{});

        const lookup = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
        for (digest) |val, i| {
            ret[2 * i] = lookup[val >> 4];
            ret[(2 * i) + 1] = lookup[@truncate(u4, val)];
        }

        return ret;
    }

    pub fn fetch(self: Self, allocator: *Allocator, deps_path: []const u8) !void {
        var source = try HttpsSource.init(allocator, self);
        defer source.deinit();

        // TODO: integrity check here

        var gzip = try gzipStream(allocator, source.reader());
        defer gzip.deinit();

        var deps_dir = try std.fs.cwd().makeOpenPath(deps_path, .{ .access_sub_paths = true });
        defer deps_dir.close();

        const digest = try self.hash();
        var dest_dir = try deps_dir.makeOpenPath(&digest, .{ .access_sub_paths = true });
        defer dest_dir.close();

        try tar.instantiate(allocator, dest_dir, gzip.reader(), 1);
    }
};

const Connection = struct {
    ssl_client: ssl.Client,
    ssl_socket: SslStream,
    socket: net.Socket,
    socket_reader: net.Socket.Reader,
    socket_writer: net.Socket.Writer,
    http_buf: [std.mem.page_size]u8,
    http_client: HttpClient,
    window: []const u8,

    const SslStream = ssl.Stream(*net.Socket.Reader, *net.Socket.Writer);
    const HttpClient = http.base.Client.Client(SslStream.DstInStream, SslStream.DstOutStream);
    const Self = @This();

    pub fn init(allocator: *Allocator, hostname: [:0]const u8, port: u16, x509: *ssl.x509.Minimal) !*Self {
        var ret = try allocator.create(Self);
        errdefer allocator.destroy(ret);

        ret.window = &[_]u8{};
        ret.ssl_client = ssl.Client.init(x509.getEngine());
        ret.ssl_client.relocate();
        try ret.ssl_client.reset(hostname, false);

        ret.socket = try net.connectToHost(allocator, hostname, port, .tcp);
        errdefer ret.socket.close();

        ret.socket_reader = ret.socket.reader();
        ret.socket_writer = ret.socket.writer();

        ret.ssl_socket = ssl.initStream(
            ret.ssl_client.getEngine(),
            &ret.socket_reader,
            &ret.socket_writer,
        );
        errdefer ret.ssl_socket.close catch {};

        ret.http_client = http.base.Client.create(
            &ret.http_buf,
            ret.ssl_socket.inStream(),
            ret.ssl_socket.outStream(),
        );

        return ret;
    }

    pub fn deinit(self: *Self) void {
        self.ssl_socket.close() catch {};
        self.socket.close();
    }

    const ReadError = HttpClient.ReadError || error{AbruptClose};
    pub const Reader = std.io.Reader(*Connection, ReadError, read);

    fn copyToBuf(self: *Self, buffer: []u8) usize {
        const len = std.math.min(buffer.len, self.window.len);
        std.mem.copy(u8, buffer[0..len], self.window[0..len]);
        self.window = self.window[len..];
        return len;
    }

    fn read(self: *Self, buffer: []u8) ReadError!usize {
        return if (self.window.len != 0)
            self.copyToBuf(buffer)
        else if (try self.http_client.readEvent()) |event| blk: {
            switch (event) {
                .closed => {
                    std.debug.print("got close\n", .{});
                    break :blk 0;
                },
                .chunk => |chunk| {
                    self.window = chunk.data;
                    break :blk self.copyToBuf(buffer);
                },
                else => |val| {
                    std.debug.print("something else: {}\n", .{val});
                    break :blk @as(usize, 0);
                },
            }
        } else 0;
    }

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
};

const HttpsSource = struct {
    allocator: *Allocator,
    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    connection: *Connection,

    const Self = @This();

    pub fn init(allocator: *Allocator, import: Import) !Self {
        var url = try import.toUrl(allocator);
        defer allocator.free(url);

        const file = try std.fs.openFileAbsolute("/etc/ssl/cert.pem", .{ .read = true });
        defer file.close();

        const certs = try file.readToEndAlloc(allocator, 500000);
        defer allocator.free(certs);

        var trust_anchor = ssl.TrustAnchorCollection.init(allocator);
        try trust_anchor.appendFromPEM(certs);

        var x509 = ssl.x509.Minimal.init(trust_anchor);

        var conn: *Connection = undefined;
        redirect: while (true) {
            const uri = try Uri.parse(url, true);
            const port = uri.port orelse 443;

            if (!std.mem.eql(u8, uri.scheme, "https")) return error.HttpsOnly;

            const hostname = try std.cstr.addNullByte(allocator, uri.host.name);
            defer allocator.free(hostname);

            conn = try Connection.init(allocator, hostname, port, &x509);
            try conn.http_client.writeHead("GET", uri.path);
            try conn.http_client.writeHeaderValue("Host", hostname);
            try conn.http_client.writeHeaderValue("User-Agent", "zkg");
            try conn.http_client.writeHeaderValue("Accept", "*/*");
            try conn.http_client.writeHeadComplete();
            try conn.ssl_socket.flush();

            var redirect = false;
            while (try conn.http_client.readEvent()) |event| {
                switch (event) {
                    .status => |status| switch (status.code) {
                        200 => {},
                        302 => redirect = true,
                        else => return error.HttpFailed,
                    },
                    .header => |header| {
                        if (redirect and std.mem.eql(u8, "location", header.name)) {
                            allocator.free(url);
                            url = try allocator.dupe(u8, header.value);
                            conn.deinit();
                            continue :redirect;
                        }
                    },
                    .head_complete => break :redirect,
                    else => |val| std.debug.print("got other: {}\n", .{val}),
                }
            }
        }

        return Self{
            .allocator = allocator,
            .trust_anchor = trust_anchor,
            .x509 = x509,
            .connection = conn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connection.deinit();
        self.trust_anchor.deinit();
    }

    pub fn reader(self: *Self) Connection.Reader {
        return self.connection.reader();
    }
};
