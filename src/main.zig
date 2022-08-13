const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const curl = @import("curl");

const Dependency = @import("Dependency.zig");
const cmds = @import("commands.zig");
const loadSystemCerts = @import("certs.zig").loadSystemCerts;
const Display = @import("Display.zig");
const utils = @import("utils.zig");

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("mbedtls/debug.h");
});

export fn gai_strerrorA(err: c_int) [*c]u8 {
    _ = err;
    return null;
}
extern fn git_mbedtls__insecure() void;
extern fn git_mbedtls__set_debug() void;

pub const log_level: std.log.Level = if (builtin.mode == .Debug) .debug else .info;
pub var display: Display = undefined;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    display.log(level, scope, format, args);
}

pub fn main() !void {
    var exit_val: u8 = 0;
    {
        const allocator = std.heap.c_allocator;
        try Display.init(&display, allocator);
        defer display.deinit();

        try curl.globalInit();
        defer curl.globalCleanup();

        if (builtin.mode == .Debug)
            c.mbedtls_debug_set_threshold(1);

        const rc = c.git_libgit2_init();
        if (rc < 0) {
            const last_error = c.git_error_last();
            std.log.err("{s}", .{last_error.*.message});
            return error.Libgit2Init;
        }
        defer _ = c.git_libgit2_shutdown();

        try loadSystemCerts(allocator);
        if (!(builtin.target.os.tag == .linux) or std.process.hasEnvVarConstant("GYRO_INSECURE"))
            git_mbedtls__insecure();

        runCommands(allocator) catch |err| {
            switch (err) {
                error.Explained => exit_val = 1,
                else => return err,
            }
        };
    }

    std.process.exit(exit_val);
}

// prints gyro command usage to stderr
fn usage() !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.writeAll("Usage: gyro [command] [options]\n\n");
    try stderr.writeAll("Commands:\n\n");

    inline for (@typeInfo(commands).Struct.decls) |decl| {
        try stderr.print("  {s: <10}  {s}\n", .{ decl.name, @field(commands, decl.name).description });
    }

    try stderr.writeAll("\nOptions:\n\n");
    try stderr.print("  {s: <10}  Print command-specific usage\n\n", .{"-h, --help"});
}

// prints usage and help for a single command
fn help(comptime name: []const u8, comptime command: type) !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.writeAll("Usage: gyro " ++ name ++ " ");
    try clap.usage(stderr, clap.Help, &command.params);
    try stderr.writeAll("\n\nOptions:\n\n");

    try clap.help(stderr, clap.Help, &command.params, .{});
    try stderr.writeAll("\n");
}

fn runCommands(allocator: std.mem.Allocator) !void {
    const stderr = std.io.getStdErr().writer();

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    // skip process name
    _ = iter.next();

    const command_name = (iter.next()) orelse {
        try usage();
        std.log.err("expected command argument", .{});

        return error.Explained;
    };

    inline for (@typeInfo(commands).Struct.decls) |decl| {
        const cmd = @field(commands, decl.name);
        // special handling for build subcommand since it passes through
        // arguments to build runner
        const is_build = std.mem.eql(u8, "build", decl.name);
        if (std.mem.eql(u8, command_name, decl.name)) {
            var args = if (!is_build) blk: {
                var diag = clap.Diagnostic{};

                var res = clap.parse(clap.Help, &cmd.params, clap.parsers.default, .{
                    .diagnostic = &diag,
                }) catch |err| {
                    // Report useful error and exit
                    diag.report(stderr, err) catch {};
                    try help(decl.name, cmd);
                    return error.Explained;
                };

                if (res.args.help) {
                    try help(decl.name, cmd);

                    return;
                }

                break :blk res;
            } else undefined;
            defer if (!is_build) args.deinit();

            try cmd.run(allocator, &args, &iter);

            return;
        }
    } else {
        try usage();
        std.log.err("{s} is not a valid command", .{command_name});

        return error.Explained;
    }
}

pub const commands = struct {
    pub const init = struct {
        pub const description = "Initialize a gyro.zzz with a link to a github repo";
        pub const params = clap.parseParamsComptime(
            \\-h, --help  Display Help
            \\<str>
            \\
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            const repo = if (res.positionals.len == 1)
                res.positionals[0]
            else {
                std.log.err("that's too many args, please just give me one in the form of a link to your github repo or just '<user>/<repo>'", .{});
                return error.Explained;
            };

            try cmds.init(allocator, repo);
        }
    };

    pub const add = struct {
        pub const description = "Add dependencies to the project";
        pub const params = clap.parseParamsComptime(
            \\-h, --help              Display Help
            \\-s, --src <str>         Set type of dependency
            \\-a, --alias <str>       Override what string the package is imported with
            \\-b, --build_dep         Add this as a build dependency
            \\-r, --root <str>        Set root path with respect to the project root, default is 'src/main.zig'
            \\    --ref <str>         Commit, tag, or branch to reference for git or github source types
            \\    --repository <str>  The package repository you want to add a package from, default is astrolabe.pm
            \\<str>
            \\
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            const src_str = res.args.src orelse "pkg";
            const src_tag = inline for (std.meta.fields(Dependency.SourceType)) |field| {
                if (std.mem.eql(u8, src_str, field.name))
                    break @field(Dependency.SourceType, field.name);
            } else {
                std.log.err("{s} is not a valid source type", .{src_str});
                return error.Explained;
            };

            // TODO: only one positional

            try cmds.add(
                allocator,
                src_tag,
                res.args.alias,
                res.args.build_dep,
                res.args.ref,
                res.args.root,
                res.args.repository,
                res.positionals[0],
            );
        }
    };

    pub const rm = struct {
        pub const description = "Remove dependencies from the project";
        pub const params = clap.parseParamsComptime(
            \\-h, --help       Display help
            \\-b, --build_dep  Remove this as a build dependency
            \\<str>
            \\
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            try cmds.rm(allocator, res.args.build_dep, res.positionals);
        }
    };

    pub const build = struct {
        pub const description = "Wrapper around 'zig build', automatically downloads dependencies";
        pub const params = clap.parseParamsComptime(
            \\-h, --help Dispaly help
            \\<str>...
            \\
        );

        pub fn run(allocator: std.mem.Allocator, _: anytype, iterator: *std.process.ArgIterator) !void {
            try cmds.build(allocator, iterator);
        }
    };

    pub const fetch = struct {
        pub const description = "Manually download dependencies and generate deps.zig file";
        pub const params = clap.parseParamsComptime(
            \\-h, --help Display help
            \\
        );

        pub fn run(allocator: std.mem.Allocator, _: anytype, _: *std.process.ArgIterator) !void {
            try cmds.fetch(allocator);
        }
    };

    pub const update = struct {
        pub const description = "Update project dependencies to latest";
        pub const params = clap.parseParamsComptime(
            \\-h, --help Display help
            \\<str>
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            try cmds.update(allocator, res.positionals);
        }
    };

    pub const publish = struct {
        pub const description = "Publish package to astrolabe.pm, requires github account";
        pub const params = clap.parseParamsComptime(
            \\-h, --help              Display help
            \\-r, --repository <str>  The package repository you want to publish to, default is astrolabe.pm
            \\<str>
            \\
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            try cmds.publish(
                allocator,
                res.args.repository,
                if (res.positionals.len > 0) res.positionals[0] else null,
            );
        }
    };

    pub const package = struct {
        pub const description = "Generate a tar file for publishing";
        pub const params = clap.parseParamsComptime(
            \\-h, --help              Display help
            \\-o, --output_dir <str>  Set package output directory
            \\<str>
            \\
        );

        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            try cmds.package(allocator, res.args.output_dir, res.positionals);
        }
    };

    pub const redirect = struct {
        pub const description = "Manage local development";
        pub const params = clap.parseParamsComptime(
            \\-h, --help         Display help
            \\-c, --clean        Undo all local redirects
            \\-a, --alias <str>  Package to redirect
            \\-p, --path <str>   Project root directory
            \\-b, --build_dep    Redirect a build dependency
            \\    --check        Return successfully if there are no redirects (intended for git pre-commit hook)
            \\
        );
        pub fn run(allocator: std.mem.Allocator, res: anytype, _: *std.process.ArgIterator) !void {
            try cmds.redirect(allocator, res.args.check, res.args.clean, res.args.build_dep, res.args.alias, res.args.path);
        }
    };
};

test "all" {
    std.testing.refAllDecls(@import("Dependency.zig"));
}
