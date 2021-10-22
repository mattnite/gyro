const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const zfetch = @import("zfetch");
const Dependency = @import("Dependency.zig");
const cmds = @import("commands.zig");
const loadSystemCerts = @import("certs.zig").loadSystemCerts;
//const threading = @import("./mbedtls_threading.zig");

const c = @cImport({
    @cInclude("git2.h");
    @cInclude("mbedtls/debug.h");
});

pub const log_level: std.log.Level = if (builtin.mode == .Debug) .debug else .info;

export fn gai_strerrorA(err: c_int) [*c]u8 {
    _ = err;
    return null;
}
extern fn git_mbedtls__insecure() void;
extern fn git_mbedtls__set_debug() void;

pub fn main() !void {
    //var gpa = std.heap.GeneralPurposeAllocator(.{
    //    //.stack_trace_frames = 10,
    //}){};
    //defer _ = gpa.deinit();

    //const allocator = &gpa.allocator;
    const allocator = std.heap.c_allocator;
    try zfetch.init();
    defer zfetch.deinit();

    //threading.setAlt();
    //defer threading.freeAlt();
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
            error.Explained => std.process.exit(1),
            else => return err,
        }
    };
}

// prints gyro command usage to stderr
fn usage() !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.writeAll("Usage: gyro [command] [options]\n\n");
    try stderr.writeAll("Commands:\n\n");

    inline for (all_commands) |cmd| {
        try stderr.print("  {s: <10}  {s}\n", .{ cmd.name, cmd.summary });
    }

    try stderr.writeAll("\nOptions:\n\n");
    try stderr.print("  {s: <10}  Print command-specific usage\n\n", .{"-h, --help"});
}

// prints usage and help for a single command
fn help(comptime command: completion.Command) !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.writeAll("Usage: gyro " ++ command.name ++ " ");
    try clap.usage(stderr, command.clap_params);
    try stderr.writeAll("\n\nOptions:\n\n");

    try clap.help(stderr, command.clap_params);
    try stderr.writeAll("\n");
}

fn runCommands(allocator: *std.mem.Allocator) !void {
    const stderr = std.io.getStdErr().writer();

    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    const command_name = (try iter.next()) orelse {
        try usage();
        std.log.err("expected command argument", .{});

        return error.Explained;
    };

    inline for (all_commands) |cmd| {
        if (std.mem.eql(u8, command_name, cmd.name)) {
            var args: cmd.parent.Args = if (!cmd.passthrough) blk: {
                var diag = clap.Diagnostic{};
                var ret = cmd.parent.Args.parse(&iter, .{ .diagnostic = &diag }) catch |err| {
                    try diag.report(stderr, err);
                    try help(cmd);

                    return error.Explained;
                };

                if (ret.flag("--help")) {
                    try help(cmd);

                    return;
                }

                break :blk ret;
            } else undefined;
            defer if (!cmd.passthrough) args.deinit();

            try cmd.parent.run(allocator, &args, &iter);

            return;
        }
    } else {
        try usage();
        std.log.err("{s} is not a valid command", .{command_name});

        return error.Explained;
    }
}

const completion = @import("completion.zig");

pub const all_commands = blk: {
    var list: []const completion.Command = &[_]completion.Command{};

    for (std.meta.declarations(commands)) |decl| {
        list = list ++ [_]completion.Command{
            @field(commands, decl.name).info,
        };
    }

    break :blk list;
};

pub const commands = struct {
    pub const init = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("init", "Initialize a gyro.zzz with a link to a github repo", init);

            cmd.addFlag('h', "help", "Display help");
            cmd.addPositional("repo", ?completion.Param.Repository, .one, "The repository to initialize this project with");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            const num = args.positionals().len;
            if (num > 1) {
                std.log.err("that's too many args, please just give me one in the form of a link to your github repo or just '<user>/<repo>'", .{});
                return error.Explained;
            }

            const repo = if (num == 1) args.positionals()[0] else null;
            try cmds.init(allocator, repo);
        }
    };

    pub const add = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("add", "Add dependencies to the project", add);

            cmd.addFlag('h', "help", "Display help");
            cmd.addOption('s', "src", "kind", enum { pkg, github, url, local }, "Set type of dependency, one of pkg, github, url, or local");
            cmd.addOption('a', "alias", "package", completion.Param.Package, "Override what string the package is imported with");
            cmd.addFlag('b', "build-dep", "Add this as a build dependency");
            cmd.addOption('r', "root", "file", completion.Param.File, "Set root path with respect to the project root, default is 'src/main.zig'");
            cmd.addPositional("package", completion.Param.Package, .many, "The package(s) to add");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            const src_str = args.option("--src") orelse "pkg";
            const src_tag = inline for (std.meta.fields(Dependency.SourceType)) |field| {
                if (std.mem.eql(u8, src_str, field.name))
                    break @field(Dependency.SourceType, field.name);
            } else {
                std.log.err("{s} is not a valid source type", .{src_str});
                return error.Explained;
            };

            try cmds.add(
                allocator,
                src_tag,
                args.option("--alias"),
                args.flag("--build-dep"),
                args.option("--root"),
                args.positionals(),
            );
        }
    };

    pub const rm = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("rm", "Remove dependencies from the project", rm);

            cmd.addFlag('h', "help", "Display help");
            cmd.addFlag('b', "build-dep", "Remove this as a build dependency");
            cmd.addPositional("package", completion.Param.Package, .many, "The package(s) to remove");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            try cmds.rm(allocator, args.flag("--build-dep"), args.positionals());
        }
    };

    pub const build = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("build", "Wrapper around 'zig build', automatically downloads dependencies", build);

            cmd.addFlag('h', "help", "Display help");
            cmd.addPositional("args", void, .many, "arguments to pass to zig build");
            cmd.passthrough = true;

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, _: *Args, iterator: *clap.args.OsIterator) !void {
            try cmds.build(allocator, iterator);
        }
    };

    pub const fetch = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("fetch", "Manually download dependencies and generate deps.zig file", fetch);

            cmd.addFlag('h', "help", "Display help");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, _: *Args, iterator: *clap.args.OsIterator) !void {
            _ = iterator;
            try cmds.fetch(allocator);
        }
    };

    pub const update = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("update", "Update project dependencies to latest", update);

            cmd.addFlag('h', "help", "Display help");
            cmd.addOption('i', "in", "package", completion.Param.Package, "Update a scoped dependency");
            cmd.addPositional("package", ?completion.Param.Package, .many, "The package(s) to update");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            try cmds.update(allocator, args.option("--in"), args.positionals());
        }
    };

    pub const publish = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("publish", "Publish package to astrolabe.pm, requires github account", publish);

            cmd.addFlag('h', "help", "Display help");
            cmd.addPositional("package", ?completion.Param.Package, .one, "The package to publish");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            try cmds.publish(allocator, if (args.positionals().len > 0) args.positionals()[0] else null);
        }
    };

    pub const package = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("package", "Generate a tar file for publishing", package);

            cmd.addFlag('h', "help", "Display help");
            cmd.addOption('o', "output-dir", "dir", completion.Param.Directory, "Set package output directory");
            cmd.addPositional("package", ?completion.Param.Package, .one, "The package(s) to package");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            try cmds.package(allocator, args.option("--output-dir"), args.positionals());
        }
    };

    pub const redirect = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("redirect", "Manage local development", redirect);

            cmd.addFlag('h', "help", "Display help");
            cmd.addFlag('c', "clean", "Undo all local redirects");
            cmd.addOption('a', "alias", "package", completion.Param.Package, "Which package to redirect");
            cmd.addOption('p', "path", "dir", completion.Param.Directory, "Project root directory");
            cmd.addFlag('b', "build-dep", "Redirect a build dependency");
            cmd.addFlag('e', "check", "Return successfully if there are no redirects (intended for git pre-commit hook)");

            cmd.done();
            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            try cmds.redirect(allocator, args.flag("--check"), args.flag("--clean"), args.flag("--build-dep"), args.option("--alias"), args.option("--path"));
        }
    };

    pub const install_completions = struct {
        pub const info: completion.Command = blk: {
            var cmd = completion.Command.init("completion", "Install shell completions", install_completions);

            cmd.addFlag('h', "help", "Display help");
            cmd.addOption('s', "shell", "shell", completion.shells.List, "The shell to install completions for. One of zsh");
            cmd.addPositional("dir", completion.Param.Directory, .one, "Where to install the completion");

            cmd.done();

            break :blk cmd;
        };

        pub const Args = info.ClapComptime();
        pub fn run(allocator: *std.mem.Allocator, args: *Args, _: *clap.args.OsIterator) !void {
            const positionals = args.positionals();

            if (positionals.len < 1) {
                std.log.err("missing completion install path", .{});

                return error.Explained;
            }

            const shell_name = args.option("--shell") orelse {
                std.log.err("missing shell", .{});

                return error.Explained;
            };

            const shell = std.meta.stringToEnum(completion.shells.List, shell_name) orelse {
                std.log.err("invalid shell", .{});

                return error.Explained;
            };

            switch (shell) {
                .zsh => {
                    const path = try std.fs.path.join(allocator, &.{ positionals[0], "_gyro" });
                    defer allocator.free(path);

                    const file = try std.fs.cwd().createFile(path, .{});
                    defer file.close();

                    try completion.shells.zsh.writeAll(file.writer(), all_commands);
                },
            }
        }
    };
};

test "all" {
    std.testing.refAllDecls(@import("Dependency.zig"));
}
