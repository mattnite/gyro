const std = @import("std");
const clap = @import("clap");
const net = @import("net");
usingnamespace @import("commands.zig");

const Command = enum {
    fetch,
    search,
    tags,
    add,
    remove,
};

fn printUsage() noreturn {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(
        \\zkg <cmd> [cmd specific options]
        \\
        \\cmds:
        \\  search  List packages matching your query
        \\  tags    List tags found in your remote
        \\  add     Add a package to your imports file
        \\  remove  Remove a package from your imports file
        \\  fetch   Download packages specified in your imports file into your
        \\          cache dir
        \\
        \\for more information: zkg <cmd> --help
        \\
        \\
    ) catch {};

    std.os.exit(1);
}

fn showHelp(comptime summary: []const u8, comptime params: anytype) void {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(summary ++ "\n\n") catch {};
    clap.help(stderr, params) catch {};
    _ = stderr.write("\n") catch {};
}

fn exitShowingError(comptime summary: []const u8, comptime params: anytype, diag: *clap.Diagnostic, err: anytype) void {
    const stderr = std.io.getStdErr().writer();
    diag.report(stderr, err) catch {};
    showHelp(summary, params);
    std.os.exit(1);
}

fn checkHelp(comptime summary: []const u8, comptime params: anytype, args: anytype) void {
    if (args.flag("--help")) {
        showHelp(summary, params);
        std.os.exit(0);
    }
}
fn parseHandlingHelpAndErrors(allocator: *std.mem.Allocator, cclap: anytype, summary: []const u8, comptime params: anytype, iter: anytype) @TypeOf(clap.Args(clap.Help, params)) {
    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(clap.Help, params).parse(allocator, iter, &diag) catch |err| {
        // Report useful error and exit
        exitShowingError(summary, params, &diag, err);
        unreachable;
    };
    checkHelp(summary, params, args);
    return args;
}

pub fn main() anyerror!void {
    const stderr = std.io.getStdErr().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    try net.init();
    defer net.deinit();

    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    const cmd_str = (try iter.next()) orelse {
        try stderr.print("no command given\n", .{});
        printUsage();
    };

    const cmd = inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, cmd_str, field.name)) {
            break @field(Command, field.name);
        }
    } else {
        try stderr.print("{} is not a valid command\n", .{cmd_str});
        printUsage();
    };

    @setEvalBranchQuota(5000);
    switch (cmd) {
        .fetch => {
            const summary = "Download packages specified in your imports file into your cache dir";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display help") catch unreachable,
                clap.parseParam("-c, --cache-dir <DIR>  cache directory, default is zig-cache") catch unreachable,
            };

            var args = try clap.ComptimeClap(clap.Help, &params).parse(allocator, &iter, null);
            defer args.deinit();

            checkHelp(summary, &params, args);

            try fetch(args.option("--cache-dir"));
        },
        .search => {
            const summary = "Lists packages matching your query";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display help") catch unreachable,
                clap.parseParam("-r, --remote <REMOTE>  Select which endpoint to query") catch unreachable,
                clap.parseParam("-t, --tag <TAG>        Filter results for specific tag") catch unreachable,
                clap.parseParam("-n, --name <NAME>      Query specific package") catch unreachable,
                clap.parseParam("-a, --author <NAME>    Filter results for specific author") catch unreachable,
                clap.parseParam("-j, --json             Print raw JSON") catch unreachable,
            };

            const cclap = clap.ComptimeClap(clap.Help, &params);
            var args = parseHandlingHelpAndErrors(allocator, cclap, summary, &params, &iter);
            defer args.deinit();

            checkHelp(summary, &params, args);

            const name_opt = args.option("--name");
            const tag_opt = args.option("--tag");
            const author_opt = args.option("--author");

            var count: usize = 0;
            if (name_opt != null) count += 1;
            if (tag_opt != null) count += 1;
            if (author_opt != null) count += 1;

            if (count > 1) return error.OnlyOneQueryType;

            const search_params = if (name_opt) |name|
                SearchParams{ .name = name }
            else if (tag_opt) |tag|
                SearchParams{ .tag = tag }
            else if (author_opt) |author|
                SearchParams{ .author = author }
            else
                SearchParams{ .all = {} };

            try search(
                allocator,
                search_params,
                args.flag("--json"),
                args.option("--remote"),
            );
        },
        .tags => {
            const summary = "List tags found in your remote";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display help") catch unreachable,
                clap.parseParam("-r, --remote <REMOTE>  Select which endpoint to query") catch unreachable,
            };

            var args = try clap.ComptimeClap(clap.Help, &params).parse(allocator, &iter, null);
            defer args.deinit();

            checkHelp(summary, &params, args);

            try tags(allocator, args.option("--remote"));
        },
        .add => {
            const summary = "Add a package to your imports file";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display help") catch unreachable,
                clap.parseParam("-r, --remote <REMOTE>  Select which endpoint to query") catch unreachable,
                clap.parseParam("-a, --alias <ALIAS>    Set the @import name of the package") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .One,
                },
            };

            var args = try clap.ComptimeClap(clap.Help, &params).parse(allocator, &iter, null);
            defer args.deinit();

            checkHelp(summary, &params, args);

            // there can only be one positional argument
            if (args.positionals().len > 1) {
                return error.TooManyPositionalArgs;
            } else if (args.positionals().len != 1) {
                return error.MissingName;
            }

            try add(allocator, args.positionals()[0], args.option("--alias"), args.option("--remote"));
        },
        .remove => {
            const summary = "Remove a package from your imports file";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display help") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .One,
                },
            };

            var args = try clap.ComptimeClap(clap.Help, &params).parse(allocator, &iter, null);
            defer args.deinit();

            checkHelp(summary, &params, args);

            // there can only be one positional argument
            if (args.positionals().len > 1) {
                return error.TooManyPositionalArgs;
            } else if (args.positionals().len != 1) {
                return error.MissingName;
            }

            try remove(allocator, args.positionals()[0]);
        },
    }
}
