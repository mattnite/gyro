const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const zfetch = @import("zfetch");
const build_options = @import("build_options");
const Dependency = @import("Dependency.zig");
usingnamespace @import("commands.zig");

//pub const io_mode = .evented;
pub const zfetch_use_buffered_io = false;
pub const log_level: std.log.Level = if (builtin.mode == .Debug) .debug else .info;

const Command = enum {
    init,
    add,
    remove,
    build,
    fetch,
    update,
    publish,
    redirect,
};

fn printUsage() noreturn {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(std.fmt.comptimePrint(
        \\gyro <cmd> [cmd specific options]
        \\
        \\cmds:
        \\  init      Initialize a gyro.zzz with a link to a github repo
        \\  add       Add dependencies to the project
        \\  remove    Remove dependency from project
        \\  build     Use exactly like 'zig build', automatically downloads dependencies
        \\  fetch     Manually download dependencies and generate deps.zig file
        \\  update    Update dependencies to latest
        \\  publish   Publish package to {s}, requires github account
        \\  redirect  Manage local development
        \\
        \\for more information: gyro <cmd> --help
        \\
        \\
    , .{build_options.default_repo})) catch {};

    std.os.exit(1);
}

fn showHelp(comptime summary: []const u8, comptime params: anytype) void {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(summary ++ "\n\n") catch {};
    clap.help(stderr, params) catch {};
    _ = stderr.write("\n") catch {};
}

fn parseHandlingHelpAndErrors(
    allocator: *std.mem.Allocator,
    comptime summary: []const u8,
    comptime params: anytype,
    iter: anytype,
) clap.ComptimeClap(clap.Help, params) {
    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(clap.Help, params).parse(allocator, iter, &diag) catch |err| {
        // Report useful error and exit
        const stderr = std.io.getStdErr().writer();
        diag.report(stderr, err) catch {};
        showHelp(summary, params);
        std.os.exit(1);
    };
    // formerly checkHelp(summary, params, args);
    if (args.flag("--help")) {
        showHelp(summary, params);
        std.os.exit(0);
    }
    return args;
}

pub fn main() !void {
    try zfetch.init();
    defer zfetch.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;
    runCommands(allocator) catch |err| {
        switch (err) {
            error.Explained => std.process.exit(1),
            else => return err,
        }
    };
}

fn runCommands(allocator: *std.mem.Allocator) !void {
    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    const stderr = std.io.getStdErr().writer();
    const cmd_str = (try iter.next()) orelse {
        try stderr.print("no command given\n", .{});
        printUsage();
    };

    const cmd = inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, cmd_str, field.name)) {
            break @field(Command, field.name);
        }
    } else {
        try stderr.print("{s} is not a valid command\n", .{cmd_str});
        printUsage();
    };

    @setEvalBranchQuota(3000);
    switch (cmd) {
        .init => {
            const summary = "Initialize a gyro.zzz with a link to a github repo";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help              Display help") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .One,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            const num = args.positionals().len;
            if (num > 1) {
                std.log.err("that's too many args, please just give me one in the form of a link to your github repo or just '<user>/<repo>'", .{});
                return error.Explained;
            }

            try init(allocator, if (num == 1) args.positionals()[0] else null);
        },
        .add => {
            const summary = "Add dependencies to the project";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help           Display help") catch unreachable,
                clap.parseParam("-s, --src <SRC>      Set type of dependency, default is 'pkg', others are 'github', 'url', or 'local'") catch unreachable,
                clap.parseParam("-a, --alias <ALIAS>  Override what string the package is imported with") catch unreachable,
                clap.parseParam("-b, --build-dep      Add this as a build dependency") catch unreachable,
                clap.parseParam("-r, --root <PATH>    Set root path with respect to the project root, default is 'src/main.zig'") catch unreachable,
                clap.parseParam("-t, --to <PKG>       Add this as a scoped dependency to a specific exported package") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .Many,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            const src_str = args.option("--src") orelse "pkg";
            const src_tag = inline for (std.meta.fields(Dependency.SourceType)) |field| {
                if (std.mem.eql(u8, src_str, field.name))
                    break @field(Dependency.SourceType, field.name);
            } else {
                std.log.err("{s} is not a valid source type", .{src_str});
                return error.Explained;
            };

            try add(
                allocator,
                src_tag,
                args.option("--alias"),
                args.flag("--build-dep"),
                args.option("--root"),
                args.option("--to"),
                args.positionals(),
            );
        },
        .remove => {
            const summary = "Remove dependency from project";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help        Display help") catch unreachable,
                clap.parseParam("-b, --build-dep   Remove a scoped dependency") catch unreachable,
                clap.parseParam("-f, --from <PKG>  Remove a scoped dependency") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .Many,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            try remove(allocator, args.flag("--build-dep"), args.option("--from"), args.positionals());
        },
        .build => try build(allocator, &iter),
        .fetch => try fetch(allocator),
        .update => {
            const summary = "Update dependencies to latest";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help      Display help") catch unreachable,
                clap.parseParam("-i, --in <PKG>  Update a scoped dependency") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .Many,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            try update(allocator, args.option("--in"), args.positionals());
        },
        .publish => {
            const summary = "Publish package to astrolabe.pm";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help              Display help") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .One,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            try publish(allocator, if (args.positionals().len > 0) args.positionals()[0] else null);
        },
        .redirect => {
            const summary = "Manage local development";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help   Display help") catch unreachable,
                clap.parseParam("-c, --clean  undo all local redirects") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .Many,
                },
            };

            return error.Todo;
        },
    }
}

test "all" {
    std.testing.refAllDecls(@import("Dependency.zig"));
}
