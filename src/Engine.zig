const std = @import("std");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");

const Engine = @This();
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const StructField = std.builtin.TypeInfo.StructField;
const UnionField = std.builtin.TypeInfo.UnionField;
const testing = std.testing;
const assert = std.debug.assert;

pub const DepTable = std.ArrayListUnmanaged(Dependency.Source);
pub const Sources = .{
    @import("pkg.zig"),
    @import("github.zig"),
    @import("local.zig"),
    @import("url.zig"),
};

pub const Edge = struct {
    const ParentIndex = union(enum) {
        root: enum {
            normal,
            build,
        },
        index: usize,
    };

    from: ParentIndex,
    to: usize,
    alias: []const u8,

    pub fn format(
        edge: Edge,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        switch (edge.from) {
            .root => |which| switch (which) {
                .normal => try writer.print("Edge: deps -> {}: {s}", .{ edge.to, edge.alias }),
                .build => try writer.print("Edge: build_deps -> {}: {s}", .{ edge.to, edge.alias }),
            },
            .index => |idx| try writer.print("Edge: {} -> {}: {s}", .{ idx, edge.to, edge.alias }),
        }
    }
};

pub const Resolutions = blk: {
    var tables_fields: [Sources.len]StructField = undefined;
    var edges_fields: [Sources.len]StructField = undefined;

    inline for (Sources) |source, i| {
        const ResolutionTable = std.ArrayListUnmanaged(source.ResolutionEntry);
        tables_fields[i] = StructField{
            .name = source.name,
            .field_type = ResolutionTable,
            .alignment = @alignOf(ResolutionTable),
            .is_comptime = false,
            .default_value = null,
        };

        const EdgeTable = std.ArrayListUnmanaged(struct {
            dep_idx: usize,
            res_idx: usize,
        });
        edges_fields[i] = StructField{
            .name = source.name,
            .field_type = EdgeTable,
            .alignment = @alignOf(EdgeTable),
            .is_comptime = false,
            .default_value = null,
        };
    }

    const Tables = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &tables_fields,
            .decls = &.{},
        },
    });

    const Edges = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &edges_fields,
            .decls = &.{},
        },
    });

    break :blk struct {
        text: []const u8,
        tables: Tables,
        edges: Edges,
        const Self = @This();

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            inline for (Sources) |source| {
                @field(self.tables, source.name).deinit(allocator);
                @field(self.edges, source.name).deinit(allocator);
            }

            allocator.free(self.text);
        }

        pub fn fromReader(allocator: *Allocator, reader: anytype) !Self {
            const text = try reader.readAllAlloc(allocator, std.math.maxInt(usize));
            errdefer allocator.free(text);

            var ret = Self{
                .text = text,
                .tables = undefined,
                .edges = undefined,
            };

            inline for (std.meta.fields(Tables)) |field|
                @field(ret.tables, field.name) = field.field_type{};

            inline for (std.meta.fields(Edges)) |field|
                @field(ret.edges, field.name) = field.field_type{};

            var line_it = std.mem.tokenize(u8, text, "\n");
            while (line_it.next()) |line| {
                var it = std.mem.tokenize(u8, line, " ");
                const first = it.next() orelse return error.EmptyLine;
                inline for (Sources) |source| {
                    if (std.mem.eql(u8, first, source.name)) {
                        try source.deserializeLockfileEntry(
                            allocator,
                            &it,
                            &@field(ret.tables, source.name),
                        );
                        break;
                    }
                } else {
                    std.log.err("unsupported lockfile prefix: {s}", .{first});
                    return error.Explained;
                }
            }

            return ret;
        }
    };
};

pub fn MultiQueueImpl(comptime Resolution: type, comptime Error: type) type {
    return std.MultiArrayList(struct {
        edge: Edge,
        thread: ?std.Thread = null,
        result: union(enum) {
            replace_me: usize,
            fill_resolution: usize,
            copy_deps: usize,
            new_entry: Resolution,
            err: Error,
        } = undefined,
        path: ?[]const u8 = null,
        deps: std.ArrayListUnmanaged(Dependency),
    });
}

pub const FetchQueue = blk: {
    var fields: [Sources.len]StructField = undefined;
    var next_fields: [Sources.len]StructField = undefined;

    inline for (Sources) |source, i| {
        const MultiQueue = MultiQueueImpl(
            source.Resolution,
            source.FetchError,
        );

        fields[i] = StructField{
            .name = source.name,
            .field_type = MultiQueue,
            .alignment = @alignOf(MultiQueue),
            .is_comptime = false,
            .default_value = null,
        };

        next_fields[i] = StructField{
            .name = source.name,
            .field_type = std.ArrayListUnmanaged(Edge),
            .alignment = @alignOf(std.ArrayListUnmanaged(Edge)),
            .is_comptime = false,
            .default_value = null,
        };
    }

    const Tables = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &fields,
            .decls = &.{},
        },
    });

    const NextType = @Type(std.builtin.TypeInfo{
        .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = &next_fields,
            .decls = &.{},
        },
    });

    break :blk struct {
        tables: Tables,
        const Self = @This();

        pub const Next = struct {
            tables: NextType,

            pub fn init() @This() {
                var ret: @This() = undefined;
                inline for (Sources) |source|
                    @field(ret.tables, source.name) = std.ArrayListUnmanaged(Edge){};

                return ret;
            }

            pub fn deinit(self: *@This(), allocator: *Allocator) void {
                inline for (Sources) |source|
                    @field(self.tables, source.name).deinit(allocator);
            }
        };

        pub fn init() Self {
            var ret: Self = undefined;

            inline for (std.meta.fields(Tables)) |field|
                @field(ret.tables, field.name) = field.field_type{};

            return ret;
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {
            inline for (Sources) |source|
                @field(self.tables, source.name).deinit(allocator);
        }

        pub fn append(
            self: *Self,
            allocator: *Allocator,
            source_type: Dependency.SourceType,
            edge: Edge,
        ) !void {
            inline for (Sources) |source| {
                if (source_type == @field(Dependency.SourceType, source.name)) {
                    try @field(self.tables, source.name).append(allocator, .{
                        .edge = edge,
                        .deps = std.ArrayListUnmanaged(Dependency){},
                    });
                    break;
                }
            } else {
                std.log.err("unsupported dependency source type: {}", .{source_type});
                assert(false);
                return error.Explained;
            }
        }

        pub fn empty(self: Self) bool {
            return inline for (Sources) |source| {
                if (@field(self.tables, source.name).len != 0) break false;
            } else true;
        }

        pub fn clearAndLoad(self: *Self, allocator: *Allocator, next: Next) !void {
            // clear current table
            inline for (Sources) |source| {
                for (@field(self.tables, source.name).items(.deps)) |*dep| {
                    dep.deinit(allocator);
                }

                @field(self.tables, source.name).shrinkRetainingCapacity(0);
                for (@field(next.tables, source.name).items) |edge| {
                    try @field(self.tables, source.name).append(allocator, .{
                        .edge = edge,
                        .deps = std.ArrayListUnmanaged(Dependency){},
                    });
                }
            }
        }

        pub fn parallelFetch(
            self: *Self,
            arena: *ArenaAllocator,
            dep_table: DepTable,
            resolutions: Resolutions,
        ) !void {
            errdefer inline for (Sources) |source|
                for (@field(self.tables, source.name).items(.thread)) |th|
                    if (th) |t|
                        t.join();

            inline for (Sources) |source| {
                for (@field(self.tables, source.name).items(.thread)) |*th, i| {
                    th.* = try std.Thread.spawn(
                        .{},
                        source.dedupeResolveAndFetch,
                        .{
                            arena,
                            dep_table.items,
                            @field(resolutions.tables, source.name).items,
                            &@field(self.tables, source.name),
                            i,
                        },
                    );
                }
            }

            inline for (Sources) |source|
                for (@field(self.tables, source.name).items(.thread)) |th|
                    th.?.join();
        }

        pub fn cleanupDeps(self: *Self, allocator: *Allocator) void {
            inline for (Sources) |source|
                for (@field(self.tables, source.name).items(.deps)) |*deps|
                    deps.deinit(allocator);
        }
    };
};

allocator: *Allocator,
arena: ArenaAllocator,
project: *Project,
dep_table: DepTable,
edges: std.ArrayListUnmanaged(Edge),
fetch_queue: FetchQueue,
resolutions: Resolutions,
paths: std.AutoHashMapUnmanaged(usize, []const u8),

pub fn init(
    allocator: *Allocator,
    project: *Project,
    lockfile_reader: anytype,
) !Engine {
    const initial_deps = project.deps.items.len + project.build_deps.items.len;
    var dep_table = try DepTable.initCapacity(allocator, initial_deps);
    errdefer dep_table.deinit(allocator);

    var fetch_queue = FetchQueue.init();
    errdefer fetch_queue.deinit(allocator);

    for (project.deps.items) |dep| {
        try dep_table.append(allocator, dep.src);
        try fetch_queue.append(allocator, dep.src, .{
            .from = .{
                .root = .normal,
            },
            .to = dep_table.items.len - 1,
            .alias = dep.alias,
        });
    }

    for (project.build_deps.items) |dep| {
        try dep_table.append(allocator, dep.src);
        try fetch_queue.append(allocator, dep.src, .{
            .from = .{
                .root = .build,
            },
            .to = dep_table.items.len - 1,
            .alias = dep.alias,
        });
    }

    const resolutions = try Resolutions.fromReader(allocator, lockfile_reader);
    errdefer resolutions.deinit(allocator);

    return Engine{
        .allocator = allocator,
        .arena = ArenaAllocator.init(allocator),
        .project = project,
        .dep_table = dep_table,
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = fetch_queue,
        .resolutions = resolutions,
        .paths = std.AutoHashMapUnmanaged(usize, []const u8){},
    };
}

pub fn deinit(self: *Engine) void {
    self.dep_table.deinit(self.allocator);
    self.edges.deinit(self.allocator);
    self.fetch_queue.deinit(self.allocator);
    self.resolutions.deinit(self.allocator);
    self.paths.deinit(self.allocator);
    self.arena.deinit();
}

pub fn fetch(self: *Engine) !void {
    defer self.fetch_queue.cleanupDeps(self.allocator);
    while (!self.fetch_queue.empty()) {
        var next = FetchQueue.Next.init();
        defer next.deinit(self.allocator);

        {
            try self.fetch_queue.parallelFetch(&self.arena, self.dep_table, self.resolutions);
            inline for (Sources) |source| {
                // update resolutions
                for (@field(self.fetch_queue.tables, source.name).items(.result)) |_, i|
                    try source.updateResolution(
                        self.allocator,
                        &@field(self.resolutions.tables, source.name),
                        self.dep_table.items,
                        &@field(self.fetch_queue.tables, source.name),
                        i,
                    );

                for (@field(self.fetch_queue.tables, source.name).items(.path)) |opt_path, i|
                    if (opt_path) |path|
                        try self.paths.putNoClobber(
                            self.allocator,
                            @field(self.fetch_queue.tables, source.name).items(.edge)[i].to,
                            path,
                        );

                // set up next batch of deps to fetch
                for (@field(self.fetch_queue.tables, source.name).items(.deps)) |deps, i| {
                    const dep_index = @field(self.fetch_queue.tables, source.name).items(.edge)[i].to;
                    for (deps.items) |dep| {
                        try self.dep_table.append(self.allocator, dep.src);
                        const edge = Edge{
                            .from = .{
                                .index = dep_index,
                            },
                            .to = self.dep_table.items.len - 1,
                            .alias = dep.alias,
                        };

                        // TODO: FIX WORKAROUND FOR COMPTIME
                        if (dep.src == Dependency.Source.pkg) {
                            try next.tables.pkg.append(self.allocator, edge);
                        } else if (dep.src == Dependency.Source.github) {
                            try next.tables.github.append(self.allocator, edge);
                        } else if (dep.src == Dependency.Source.local) {
                            try next.tables.local.append(self.allocator, edge);
                        } else if (dep.src == Dependency.Source.url) {
                            try next.tables.url.append(self.allocator, edge);
                        }

                        // OH NO I CAN'T DO AN ELSE HERE WITHOUT THE COMPILER CRASHING
                    }
                }

                // copy edges
                try self.edges.appendSlice(
                    self.allocator,
                    @field(self.fetch_queue.tables, source.name).items(.edge),
                );
            }
        }

        try self.fetch_queue.clearAndLoad(self.allocator, next);
    }

    // TODO: check for circular dependencies
}

pub fn writeLockfile(self: Engine, writer: anytype) !void {
    inline for (Sources) |source|
        try source.serializeResolutions(@field(self.resolutions.tables, source.name).items, writer);
}

pub fn writeDepBeginRoot(self: *Engine, writer: anytype, indent: usize, edge: Edge) !void {
    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("pub const {s} = Pkg{{\n", .{
        try utils.escape(&self.arena.allocator, edge.alias),
    });

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".name = \"{s}\",\n", .{edge.alias});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".path = FileSource{{\n", .{});

    try writer.writeByteNTimes(' ', 4 * (indent + 2));
    try writer.print(".path = \"{s}\",\n", .{self.paths.get(edge.to).?});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print("}},\n", .{});

    _ = self;
}

pub fn writeDepEndRoot(writer: anytype, indent: usize) !void {
    try writer.writeByteNTimes(' ', 4 * (1 + indent));
    try writer.print("}},\n", .{});

    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("}};\n\n", .{});
}

pub fn writeDepBegin(self: Engine, writer: anytype, indent: usize, edge: Edge) !void {
    try writer.writeByteNTimes(' ', 4 * indent);
    try writer.print("Pkg{{\n", .{});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".name = \"{s}\",\n", .{edge.alias});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print(".path = FileSource{{\n", .{});

    try writer.writeByteNTimes(' ', 4 * (indent + 2));
    try writer.print(".path = \"{s}\",\n", .{self.paths.get(edge.to).?});

    try writer.writeByteNTimes(' ', 4 * (indent + 1));
    try writer.print("}},\n", .{});

    _ = self;
}

pub fn writeDepEnd(writer: anytype, indent: usize) !void {
    try writer.writeByteNTimes(' ', 4 * (1 + indent));
    try writer.print("}},\n", .{});
}

pub fn writeDepsZig(self: *Engine, writer: anytype) !void {
    try writer.print(
        \\const std = @import("std");
        \\const Pkg = std.build.Pkg;
        \\const FileSource = std.build.FileSource;
        \\
        \\pub const pkgs = struct {{
        \\
    , .{});

    for (self.edges.items) |edge| {
        switch (edge.from) {
            .root => |root| if (root == .normal) {
                var stack = std.ArrayList(struct {
                    current: usize,
                    edge_idx: usize,
                    has_deps: bool,
                }).init(self.allocator);
                defer stack.deinit();

                var current = edge.to;
                var edge_idx = 1 + edge.to;
                var has_deps = false;
                try self.writeDepBeginRoot(writer, 1 + stack.items.len, edge);

                while (true) {
                    while (edge_idx < self.edges.items.len) : (edge_idx += 1) {
                        const root_level = stack.items.len == 0;
                        switch (self.edges.items[edge_idx].from) {
                            .index => |idx| if (idx == current) {
                                if (!has_deps) {
                                    const offset: usize = if (root_level) 2 else 3;
                                    try writer.writeByteNTimes(' ', 4 * (stack.items.len + offset));
                                    try writer.print(".dependencies = &[_]Pkg{{\n", .{});
                                    has_deps = true;
                                }

                                try stack.append(.{
                                    .current = current,
                                    .edge_idx = edge_idx,
                                    .has_deps = has_deps,
                                });

                                const offset: usize = if (root_level) 2 else 3;
                                try self.writeDepBegin(writer, offset + stack.items.len, self.edges.items[edge_idx]);
                                current = edge_idx;
                                edge_idx += 1;
                                has_deps = false;
                                break;
                            },
                            else => {},
                        }
                    } else if (stack.items.len > 0) {
                        if (has_deps) {
                            try writer.writeByteNTimes(' ', 4 * (stack.items.len + 3));
                            try writer.print("}},\n", .{});
                        }

                        const offset: usize = if (stack.items.len == 1) 2 else 3;
                        try writer.writeByteNTimes(' ', 4 * (stack.items.len + offset));
                        try writer.print("}},\n", .{});

                        const pop = stack.pop();
                        current = pop.current;
                        edge_idx = 1 + pop.edge_idx;
                        has_deps = pop.has_deps;
                    } else {
                        if (has_deps) {
                            try writer.writeByteNTimes(' ', 8);
                            try writer.print("}},\n", .{});
                        }

                        break;
                    }
                }

                try writer.writeByteNTimes(' ', 4);
                try writer.print("}};\n\n", .{});
            },
            else => {},
        }
    }
    try writer.print("    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {{\n", .{});
    for (self.edges.items) |edge| {
        switch (edge.from) {
            .root => |root| if (root == .normal) {
                try writer.print("        artifact.addPackage(pkgs.{s});\n", .{
                    edge.alias,
                });
            },
            else => {},
        }
    }
    try writer.print("    }}\n", .{});

    try writer.print("}};\n", .{});

    if (self.project.packages.count() == 0)
        return;

    try writer.print("\npub const exports = struct {{\n", .{});
    var it = self.project.packages.iterator();
    while (it.next()) |pkg| {
        const path: []const u8 = pkg.value_ptr.root orelse utils.default_root;
        try writer.print(
            \\    pub const {s} = Pkg{{
            \\        .name = "{s}",
            \\        .path = "{s}",
            \\
        , .{
            try utils.escape(&self.arena.allocator, pkg.value_ptr.name),
            pkg.value_ptr.name,
            path,
        });

        if (self.project.deps.items.len > 0) {
            try writer.print("        .dependencies = &[_]Pkg{{\n", .{});
            for (self.edges.items) |edge| {
                switch (edge.from) {
                    .root => |root| if (root == .normal) {
                        try writer.print("            pkgs.{s},\n", .{
                            edge.alias,
                        });
                    },
                    else => {},
                }
            }
            try writer.print("        }},\n", .{});
        }

        try writer.print("    }};\n", .{});
    }
    try writer.print("}};\n", .{});
}

pub fn genBuildDeps(self: Engine) ![]std.build.Pkg {
    _ = self;
    return &[_]std.build.Pkg{};
}

test "Resolutions" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var resolutions = try Resolutions.fromReader(testing.allocator, fb.reader());
    defer resolutions.deinit(testing.allocator);
}

test "FetchQueue" {
    var fetch_queue = FetchQueue.init();
    defer fetch_queue.deinit(testing.allocator);
}

test "fetch" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var engine = Engine{
        .allocator = testing.allocator,
        .arena = ArenaAllocator.init(testing.allocator),
        .dep_table = DepTable{},
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = FetchQueue.init(),
        .resolutions = try Resolutions.fromReader(testing.allocator, fb.reader()),
    };
    defer engine.deinit();

    try engine.fetch();
}

test "writeLockfile" {
    var text = "".*;
    var fb = std.io.fixedBufferStream(&text);
    var engine = Engine{
        .allocator = testing.allocator,
        .arena = ArenaAllocator.init(testing.allocator),
        .dep_table = DepTable{},
        .edges = std.ArrayListUnmanaged(Edge){},
        .fetch_queue = FetchQueue.init(),
        .resolutions = try Resolutions.fromReader(testing.allocator, fb.reader()),
    };
    defer engine.deinit();

    try engine.writeLockfile(fb.writer());
}
