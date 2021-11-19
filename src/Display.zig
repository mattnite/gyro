const std = @import("std");
const builtin = @import("builtin");
const version = @import("version");
const uri = @import("uri");

const assert = std.debug.assert;

pub const Size = struct {
    rows: usize,
    cols: usize,
};

pub const Source = union(enum) {
    const Git = struct {
        url: []const u8,
        commit: []const u8,
    };

    git: Git,
    sub: Git,
    pkg: struct {
        repository: []const u8,
        user: []const u8,
        name: []const u8,
        semver: version.Semver,
    },
    url: []const u8,
};

const EntryUpdate = union(enum) {
    progress: Progress,
    err: void,
};

const Progress = struct {
    current: usize,
    total: usize,
};

const Entry = struct {
    tag: []const u8,
    label: []const u8,
    version: []const u8,
    progress: Progress,
    err: bool,
};

const UpdateState = struct {
    current_len: usize,
    entries: std.ArrayList(Entry),
    progress: std.AutoHashMap(usize, Progress),
    errors: std.AutoHashMap(usize, void),
    new_size: ?Size,

    fn init(allocator: *std.mem.Allocator) UpdateState {
        return UpdateState{
            .current_len = 0,
            .entries = std.ArrayList(Entry).init(allocator),
            .progress = std.AutoHashMap(usize, Progress).init(allocator),
            .errors = std.AutoHashMap(usize, void).init(allocator),
            .new_size = null,
        };
    }

    fn deinit(self: *UpdateState) void {
        self.entries.deinit();
        self.progress.deinit();
        self.errors.deinit();
    }

    fn hasChanges(self: UpdateState) bool {
        return self.new_size != null or
            self.entries.items.len > 0 or
            self.progress.count() > 0 or
            self.errors.count() > 0;
    }

    fn clear(self: *UpdateState) void {
        self.entries.clearRetainingCapacity();
        self.progress.clearRetainingCapacity();
        self.errors.clearRetainingCapacity();
        self.new_size = null;
    }
};

const Self = @This();

mode: union(enum) {
    direct_log: void,
    ansi: struct {
        allocator: *std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        entries: std.ArrayList(Entry),
        logs: std.ArrayList([]const u8),
        depth: usize,
        size: Size,

        running: std.atomic.Atomic(bool),
        mtx: std.Thread.Mutex,
        logs_mtx: std.Thread.Mutex,
        render_thread: std.Thread,

        // state maps that get swapped
        collector: *UpdateState,
        scratchpad: *UpdateState,

        fifo: std.fifo.LinearFifo(u8, .{ .Dynamic = {} }),
    },
},

pub fn init(location: *Self, allocator: *std.mem.Allocator) !void {
    var size = Size{
        .rows = 24,
        .cols = 80,
    };

    switch (builtin.target.os.tag) {
        .windows => {
            const c = @cImport({
                @cInclude("windows.h");
            });

            var csbi: c.CONSOLE_SCREEN_BUFFER_INFO = undefined;

            if (0 == c.GetConsoleScreenBufferInfo(c.GetStdHandle(c.STD_OUTPUT_HANDLE), &csbi) or
                std.process.hasEnvVarConstant("GYRO_DIRECT_LOG"))
            {
                location.* = Self{ .mode = .{ .direct_log = {} } };
                return;
            }

            size.rows = @intCast(usize, csbi.srWindow.Bottom - csbi.srWindow.Top + 1);
            size.cols = @intCast(usize, csbi.srWindow.Right - csbi.srWindow.Left + 1);
        },
        else => {
            const c = @cImport({
                @cInclude("sys/ioctl.h");
                @cInclude("unistd.h");
            });

            var winsize: c.winsize = undefined;
            const rc = c.ioctl(0, c.TIOCGWINSZ, &winsize);
            if (rc != 0 or c.isatty(std.io.getStdOut().handle) != 1 or
                std.process.hasEnvVarConstant("GYRO_DIRECT_LOG"))
            {
                location.* = Self{ .mode = .{ .direct_log = {} } };
                return;
            }

            size.rows = winsize.ws_row;
            size.cols = winsize.ws_col;
        },
    }

    const collector = try allocator.create(UpdateState);
    errdefer allocator.destroy(collector);

    const scratchpad = try allocator.create(UpdateState);
    errdefer allocator.destroy(scratchpad);

    collector.* = UpdateState.init(allocator);
    scratchpad.* = UpdateState.init(allocator);

    location.* = Self{
        .mode = .{
            .ansi = .{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .running = std.atomic.Atomic(bool).init(true),
                .mtx = std.Thread.Mutex{},
                .logs_mtx = std.Thread.Mutex{},
                .render_thread = try std.Thread.spawn(.{}, renderTask, .{location}),
                .entries = std.ArrayList(Entry).init(allocator),
                .logs = std.ArrayList([]const u8).init(allocator),
                .size = size,
                .depth = 0,
                .collector = collector,
                .scratchpad = scratchpad,
                .fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(allocator),
            },
        },
    };
}

pub fn deinit(self: *Self) void {
    switch (self.mode) {
        .direct_log => {},
        .ansi => |*ansi| {
            ansi.running.store(false, .SeqCst);
            ansi.render_thread.join();

            const stderr = std.io.getStdErr().writer();
            if (ansi.logs.items.len > 1) {
                stderr.writeByteNTimes('-', ansi.size.cols) catch {};
                stderr.writeByte('\n') catch {};
                stderr.writeAll("logs captured during fetch:\n") catch {};
            }

            for (ansi.logs.items) |msg|
                stderr.writeAll(msg) catch continue;

            ansi.entries.deinit();
            ansi.collector.deinit();
            ansi.scratchpad.deinit();
            ansi.allocator.destroy(ansi.collector);
            ansi.allocator.destroy(ansi.scratchpad);
            ansi.fifo.deinit();
            ansi.arena.deinit();
        },
    }
}

pub fn log(
    self: *Self,
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (self.mode) {
        .direct_log => std.log.defaultLog(level, scope, format, args),
        .ansi => |*ansi| {
            const level_txt = comptime level.asText();
            const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            const message = std.fmt.allocPrint(ansi.allocator, level_txt ++ prefix2 ++ format ++ "\n", args) catch return;

            ansi.logs_mtx.lock();
            defer ansi.logs_mtx.unlock();

            ansi.logs.append(message) catch {};
        },
    }
}

fn entryFromGit(
    self: *Self,
    tag: []const u8,
    url: []const u8,
    commit: []const u8,
) !Entry {
    const link = try uri.parse(url);
    const begin = if (link.scheme) |scheme| scheme.len + 3 else 0;
    const end_offset: usize = if (std.mem.endsWith(u8, url, ".git")) 4 else 0;

    return Entry{
        .tag = tag,
        .label = try self.mode.ansi.arena.allocator.dupe(u8, url[begin .. url.len - end_offset]),
        .version = try self.mode.ansi.arena.allocator.dupe(u8, commit[0..std.math.min(commit.len, 8)]),
        .progress = .{
            .current = 0,
            .total = 1,
        },
        .err = false,
    };
}

pub fn createEntry(self: *Self, source: Source) !usize {
    switch (self.mode) {
        .direct_log => {
            switch (source) {
                .git => |git| std.log.info("cloning {s} {s}", .{
                    git.url,
                    git.commit[0..std.math.min(git.commit.len, 8)],
                }),
                .sub => |sub| std.log.info("cloning submodule {s}", .{
                    sub.url,
                }),
                .pkg => |pkg| std.log.info("fetching package {s}/{s}/{s}", .{
                    pkg.repository,
                    pkg.user,
                    pkg.name,
                }),
                .url => |url| std.log.info("fetching tarball {s}", .{
                    url,
                }),
            }

            return 0;
        },
        .ansi => |*ansi| {
            const allocator = &ansi.arena.allocator;
            const new_entry = switch (source) {
                .git => |git| try self.entryFromGit("git", git.url, git.commit),
                .sub => |sub| try self.entryFromGit("sub", sub.url, sub.commit),
                .pkg => |pkg| Entry{
                    .tag = "pkg",
                    .label = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
                        pkg.repository,
                        pkg.user,
                        pkg.name,
                    }),
                    .version = try std.fmt.allocPrint(allocator, "{}", .{pkg.semver}),
                    .progress = .{
                        .current = 0,
                        .total = 1,
                    },
                    .err = false,
                },
                .url => |url| Entry{
                    .tag = "url",
                    .label = try ansi.allocator.dupe(u8, url),
                    .version = "",
                    .progress = .{
                        .current = 0,
                        .total = 1,
                    },
                    .err = false,
                },
            };

            ansi.mtx.lock();
            defer ansi.mtx.unlock();

            try ansi.collector.entries.append(new_entry);
            return ansi.collector.current_len +
                ansi.collector.entries.items.len - 1;
        },
    }
}

pub fn updateEntry(self: *Self, handle: usize, update: EntryUpdate) !void {
    switch (self.mode) {
        .direct_log => {},
        .ansi => |*ansi| {
            ansi.mtx.lock();
            defer ansi.mtx.unlock();

            switch (update) {
                .progress => |p| try ansi.collector.progress.put(handle, p),
                .err => try ansi.collector.errors.put(handle, {}),
            }
        },
    }
}

pub fn updateSize(self: *Self, new_size: Size) void {
    switch (self.mod) {
        .direct_log => {},
        .ansi => |ansi| {
            ansi.mtx.lock();
            defer ansi.mtx.unlock();

            ansi.collector.new_size = new_size;
        },
    }
}

fn updateState(self: *Self) !void {
    switch (self.mode) {
        .direct_log => unreachable,
        .ansi => |*ansi| {
            try ansi.entries.appendSlice(ansi.scratchpad.entries.items);
            if (ansi.scratchpad.new_size) |new_size|
                ansi.size = new_size;

            {
                var it = ansi.scratchpad.progress.iterator();
                while (it.next()) |entry| {
                    const idx = entry.key_ptr.*;
                    assert(idx <= ansi.entries.items.len);
                    ansi.entries.items[idx].progress = entry.value_ptr.*;
                }
            }

            {
                var it = ansi.scratchpad.errors.iterator();
                while (it.next()) |entry| {
                    const idx = entry.key_ptr.*;
                    ansi.entries.items[idx].err = true;
                }
            }
        },
    }
}

fn renderTask(self: *Self) !void {
    const stdout = std.io.getStdOut().writer();
    var done = false;
    while (!done) : (std.time.sleep(std.time.ns_per_s * 0.1)) {
        if (!self.mode.ansi.running.load(.SeqCst))
            done = true;

        {
            self.mode.ansi.mtx.lock();
            defer self.mode.ansi.mtx.unlock();

            self.mode.ansi.scratchpad.current_len = self.mode.ansi.collector.current_len +
                self.mode.ansi.collector.entries.items.len;
            std.mem.swap(UpdateState, self.mode.ansi.collector, self.mode.ansi.scratchpad);
        }

        try self.updateState();
        if (self.mode.ansi.entries.items.len > 0 and
            (self.mode.ansi.scratchpad.hasChanges() or
            self.mode.ansi.depth != self.mode.ansi.entries.items.len))
        {
            try self.render(stdout);
        }

        self.mode.ansi.scratchpad.clear();
    }
}

fn drawBar(writer: anytype, width: usize, percent: usize) !void {
    if (width < 3) {
        try writer.writeByteNTimes(' ', width);
        return;
    }

    const bar_width = width - 2;
    const cells = std.math.min(percent * bar_width / 100, bar_width);
    try writer.writeByte('[');
    try writer.writeByteNTimes('#', cells);
    try writer.writeByteNTimes(' ', bar_width - cells);
    try writer.writeByte(']');
}

fn render(self: *Self, stdout: anytype) !void {
    switch (self.mode) {
        .direct_log => unreachable,
        .ansi => |*ansi| {
            const writer = ansi.fifo.writer();
            defer {
                ansi.fifo.count = 0;
                ansi.fifo.head = 0;
            }

            const spacing = 20;
            const short_mode = ansi.size.cols < 50;

            // calculations
            const version_width = 8;
            const variable = ansi.size.cols -| 26;
            const label_width = if (variable < spacing)
                variable
            else
                spacing + ((variable - spacing) / 2);

            const bar_width = if (variable < spacing)
                0
            else
                ((variable - spacing) / 2) + if (variable % 2 == 1) @as(usize, 1) else 0;

            if (ansi.depth < ansi.entries.items.len) {
                try writer.writeByteNTimes('\n', ansi.entries.items.len - ansi.depth);
                ansi.depth = ansi.entries.items.len;
            }

            // up n lines at beginning
            try writer.print("\x1b[{}F", .{ansi.depth});

            for (ansi.entries.items) |entry| {
                if (short_mode) {
                    if (entry.err)
                        try writer.writeAll("\x1b[31m");

                    try writer.writeAll(entry.label[0..std.math.min(entry.label.len, ansi.size.cols)]);

                    if (entry.err) {
                        try writer.writeAll("\x1b[0m");
                    }

                    try writer.writeAll("\x1b[1B\x0d");

                    continue;
                }

                const percent = std.math.min(entry.progress.current * 100 /
                    entry.progress.total, 100);

                if (entry.err)
                    try writer.writeAll("\x1b[31m");

                try writer.print("{s} ", .{entry.tag});
                if (entry.label.len > label_width) {
                    try writer.writeAll(entry.label[0 .. label_width - 3]);
                    try writer.writeAll("...");
                } else {
                    try writer.writeAll(entry.label);
                    try writer.writeByteNTimes(' ', label_width - entry.label.len);
                }

                try writer.writeByte(' ');
                try writer.writeAll(entry.version[0..std.math.min(version_width, entry.version.len)]);
                if (entry.version.len < label_width)
                    try writer.writeByteNTimes(' ', version_width - entry.version.len);

                try writer.writeByte(' ');
                try drawBar(writer, bar_width, percent);
                try writer.print(" {: >3}%", .{percent});
                if (entry.err) {
                    try writer.writeAll(" ERROR \x1b[0m");
                } else {
                    try writer.writeByteNTimes(' ', 7);
                }

                try writer.writeAll("\x1b[1E");
            }

            try stdout.writeAll(ansi.fifo.readableSlice(0));
        },
    }
}
