const std = @import("std");
const ssl = @import("ssl");

const Self = @This();

fn FixedGrowBuffer(comptime T: type, comptime max_len: usize) type {
    return struct {
        offset: usize,
        buffer: [max_len]T,

        pub fn init() FixedGrowBuffer(T, max_len) {
            return FixedGrowBuffer(T, max_len){
                .offset = 0,
                .buffer = undefined,
            };
        }

        pub fn reset(self: *FixedGrowBuffer(T, max_len)) void {
            self.offset = 0;
        }

        pub fn write(self: *FixedGrowBuffer(T, max_len), data: []const T) error{OutOfMemory}!void {
            if (self.offset + data.len > self.buffer.len)
                return error.OutOfMemory;
            std.mem.copy(T, self.buffer[self.offset..], data);
            self.offset += data.len;
        }

        pub fn span(self: *FixedGrowBuffer(T, max_len)) []T {
            return self.buffer[0..self.offset];
        }

        pub fn constSpan(self: *FixedGrowBuffer(T, max_len)) []const T {
            return self.buffer[0..self.offset];
        }
    };
}

const class = ssl.c.br_x509_class{
    .context_size = @sizeOf(Self),
    .start_chain = start_chain,
    .start_cert = start_cert,
    .append = append,
    .end_cert = end_cert,
    .end_chain = end_chain,
    .get_pkey = get_pkey,
};

vtable: [*c]const ssl.c.br_x509_class = &class,
x509: union(enum) {
    minimal: ssl.c.br_x509_minimal_context,
    known_key: ssl.c.br_x509_knownkey_context,
},

allocator: *std.mem.Allocator,
certificates: std.ArrayList(ssl.DERCertificate),

current_cert_valid: bool = undefined,
temp_buffer: FixedGrowBuffer(u8, 2048) = undefined,

server_name: ?[]const u8 = null,

const empty_trust_anchor_set = ssl.TrustAnchorCollection.init(std.testing.failing_allocator);

pub fn init(allocator: *std.mem.Allocator) Self {
    return Self{
        .x509 = .{
            .minimal = ssl.x509.Minimal.init(empty_trust_anchor_set).engine,
        },
        .allocator = allocator,
        .certificates = std.ArrayList(ssl.DERCertificate).init(allocator),
    };
}

pub fn deinit(self: Self) void {
    for (self.certificates.items) |cert| {
        cert.deinit();
    }
    self.certificates.deinit();

    if (self.server_name) |name| {
        self.allocator.free(name);
    }
}

pub fn setToKnownKey(self: *Self, key: PublicKey) void {
    self.x509.x509_known_key = ssl.c.br_x509_knownkey_context{
        .vtable = &c.br_x509_knownkey_vtable,
        .pkey = key.toX509(),
        .usages = (key.usages orelse 0) | ssl.c.BR_KEYTYPE_KEYX | ssl.c.BR_KEYTYPE_SIGN, // always allow a stored key for key-exchange
    };
}

fn returnTypeOf(comptime Class: type, comptime name: []const u8) type {
    return @typeInfo(std.meta.Child(std.meta.fieldInfo(Class, name).field_type)).Fn.return_type.?;
}

fn virtualCall(object: anytype, comptime name: []const u8, args: anytype) returnTypeOf(ssl.c.br_x509_class, name) {
    return @call(.{}, @field(object.vtable.?.*, name).?, .{&object.vtable} ++ args);
}

fn proxyCall(self: anytype, comptime name: []const u8, args: anytype) returnTypeOf(ssl.c.br_x509_class, name) {
    return switch (self.x509) {
        .minimal => |*m| virtualCall(m, name, args),
        .known_key => |*k| virtualCall(k, name, args),
    };
}

fn fromPointer(ctx: anytype) if (@typeInfo(@TypeOf(ctx)).Pointer.is_const) *const Self else *Self {
    return if (@typeInfo(@TypeOf(ctx)).Pointer.is_const)
        return @fieldParentPtr(Self, "vtable", @ptrCast(*const [*c]const ssl.c.br_x509_class, ctx))
    else
        return @fieldParentPtr(Self, "vtable", @ptrCast(*[*c]const ssl.c.br_x509_class, ctx));
}

fn start_chain(ctx: [*c][*c]const ssl.c.br_x509_class, server_name: [*c]const u8) callconv(.C) void {
    const self = fromPointer(ctx);
    std.debug.warn("start_chain({0}, {1})\n", .{
        ctx,
        std.mem.spanZ(server_name),
    });

    self.proxyCall("start_chain", .{server_name});

    for (self.certificates.items) |cert| {
        cert.deinit();
    }
    self.certificates.shrink(0);

    if (self.server_name) |name| {
        self.allocator.free(name);
    }
    self.server_name = null;

    self.server_name = std.mem.dupe(self.allocator, u8, std.mem.spanZ(server_name)) catch null;
}

fn start_cert(ctx: [*c][*c]const ssl.c.br_x509_class, length: u32) callconv(.C) void {
    const self = fromPointer(ctx);
    std.debug.warn("start_cert({0}, {1})\n", .{
        ctx,
        length,
    });
    self.proxyCall("start_cert", .{length});

    self.temp_buffer = FixedGrowBuffer(u8, 2048).init();
    self.current_cert_valid = true;
}

fn append(ctx: [*c][*c]const ssl.c.br_x509_class, buf: [*c]const u8, len: usize) callconv(.C) void {
    const self = fromPointer(ctx);
    std.debug.warn("append({0}, {1}, {2})\n", .{
        ctx,
        buf,
        len,
    });
    self.proxyCall("append", .{ buf, len });

    self.temp_buffer.write(buf[0..len]) catch {
        std.debug.warn("too much memory!\n", .{});
        self.current_cert_valid = false;
    };
}

fn end_cert(ctx: [*c][*c]const ssl.c.br_x509_class) callconv(.C) void {
    const self = fromPointer(ctx);
    std.debug.warn("end_cert({})\n", .{
        ctx,
    });
    self.proxyCall("end_cert", .{});

    if (self.current_cert_valid) {
        const cert = ssl.DERCertificate{
            .allocator = self.allocator,
            .data = std.mem.dupe(self.allocator, u8, self.temp_buffer.constSpan()) catch return, // sad, but no other choise
        };
        errdefer cert.deinit();

        self.certificates.append(cert) catch return;
    }
}

fn end_chain(ctx: [*c][*c]const ssl.c.br_x509_class) callconv(.C) c_uint {
    const self = fromPointer(ctx);
    const err = self.proxyCall("end_chain", .{});
    std.debug.warn("end_chain({}) → {}\n", .{
        ctx,
        err,
    });

    std.debug.warn("Received {} certificates for {}!\n", .{
        self.certificates.items.len,
        self.server_name,
    });

    return if (err == ssl.c.BR_ERR_X509_NOT_TRUSTED) 0 else err;
}

fn get_pkey(
    ctx: [*c]const [*c]const ssl.c.br_x509_class,
    usages: [*c]c_uint,
) callconv(.C) [*c]const ssl.c.br_x509_pkey {
    const self = fromPointer(ctx);

    const pkey = self.proxyCall("get_pkey", .{usages});
    std.debug.warn("get_pkey({}, {}) → {}\n", .{
        ctx,
        usages,
        pkey,
    });

    return pkey;
}

fn saveCertificates(self: Self, folder: []const u8) !void {
    var trust_store_dir = try std.fs.cwd().openDir("trust-store", .{ .access_sub_paths = true, .iterate = false });
    defer trust_store_dir.close();

    trust_store_dir.makeDir(folder) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var server_dir = try trust_store_dir.openDir(folder, .{ .access_sub_paths = true, .iterate = false });
    defer server_dir.close();

    for (self.certificates.items) |cert, index| {
        var name_buf: [64]u8 = undefined;
        var name = try std.fmt.bufPrint(&name_buf, "cert-{}.der", .{index});

        var file = try server_dir.createFile(name, .{ .exclusive = false });
        defer file.close();

        try file.writeAll(cert.data);
    }
}

pub fn extractPublicKey(self: Self, allocator: *std.mem.Allocator) !ssl.PublicKey {
    var usages: c_uint = 0;
    const pkey = self.proxyCall("get_pkey", .{usages});
    std.debug.assert(pkey != null);
    var key = try ssl.PublicKey.fromX509(allocator, pkey.*);
    key.usages = usages;
    return key;
}

pub fn getEngine(self: *Self) *[*c]const ssl.c.br_x509_class {
    return &self.vtable;
}
