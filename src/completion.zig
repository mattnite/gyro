const std = @import("std");
const clap = @import("clap");

const assert = std.debug.assert;

pub const Param = struct {
    pub const Repository = struct {};
    pub const Directory = struct {};
    pub const Package = struct {};
    pub const AnyFile = struct {};
    pub const File = struct {};

    short_name: ?u8 = null,
    long_name: ?[]const u8 = null,
    description: []const u8,
    value_name: ?[]const u8 = null,
    size: clap.Values = .None,
    data: type,
};

const ClapParam = clap.Param(clap.Help);
pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    params: []const Param = &[_]Param{},
    clap_params: []const ClapParam = &[_]ClapParam{},
    parent: type,

    passthrough: bool = false,

    pub fn init(comptime name: []const u8, summary: []const u8, parent: type) Command {
        return .{
            .name = name,
            .summary = summary,
            .parent = parent,
        };
    }

    pub fn addFlag(comptime self: *Command, comptime short: ?u8, comptime long: ?[]const u8, comptime description: []const u8) void {
        assert(short != null or long != null);

        self.params = self.params ++ [_]Param{.{
            .short_name = short,
            .long_name = long,
            .description = description,
            .data = void,
        }};
    }

    pub fn addOption(comptime self: *Command, comptime short: ?u8, comptime long: ?[]const u8, comptime value_name: []const u8, data: type, comptime description: []const u8) void {
        assert(short != null or long != null);

        self.params = self.params ++ [_]Param{.{
            .short_name = short,
            .long_name = long,
            .description = description,
            .value_name = value_name,
            .data = data,
            .size = .One,
        }};
    }

    pub fn addPositional(comptime self: *Command, comptime value_name: []const u8, data: type, comptime size: clap.Values, comptime description: []const u8) void {
        self.params = self.params ++ [_]Param{.{
            .description = description,
            .value_name = value_name,
            .data = data,
            .size = size,
        }};
    }

    pub fn done(comptime self: *Command) void {
        self.clap_params = &[_]ClapParam{};

        for (self.params) |p| {
            self.clap_params = self.clap_params ++ [_]ClapParam{.{
                .id = .{
                    .msg = p.description,
                    .value = p.value_name orelse "",
                },
                .names = .{
                    .short = p.short_name,
                    .long = p.long_name,
                },
                .takes_value = p.size,
            }};
        }
    }

    pub fn ClapComptime(comptime self: *const Command) type {
        return clap.ComptimeClap(clap.Help, self.clap_params);
    }
};

pub const shells = struct {
    pub const List = enum { zsh };

    pub const zsh = struct {
        pub fn writeAll(writer: anytype, comptime commands: []const Command) !void {
            try writer.writeAll(
                \\#compdef gyro
                \\
                \\function _gyro {
                \\  local -a __subcommands
                \\  local line state
                \\
                \\  __subcommands=(
                \\
            );

            inline for (commands) |cmd| {
                try writer.print("    \"{s}:{}\"\n", .{ cmd.name, std.zig.fmtEscapes(cmd.summary) });
            }

            try writer.writeAll(
                \\  )
                \\
                \\  _arguments -C \
                \\    "1: :->subcommand" \
                \\    "*::arg:->args"
                \\
                \\  case $state in
                \\    subcommand)
                \\      _describe 'command' __subcommands
                \\      ;;
                \\    args)
                \\      __subcommand="__gyro_cmd_${line[1]}"
                \\      if type $__subcommand >/dev/null; then
                \\        $__subcommand
                \\      fi
                \\      ;;
                \\  esac
                \\}
                \\
                \\
            );

            inline for (commands) |cmd| {
                try writer.print("function __gyro_cmd_{s} {{\n", .{cmd.name});

                try writer.writeAll("  _arguments \\\n");

                inline for (cmd.params) |param, i| {
                    try writer.writeAll("    ");

                    if (param.short_name == null and param.long_name == null) {
                        // positional
                        try writer.writeAll("\"");
                    } else {
                        // flag or option
                        if (param.short_name == null) {
                            try writer.print("--{s}", .{param.long_name});
                        } else if (param.long_name == null) {
                            try writer.print("-{c}", .{param.short_name});
                        } else {
                            try writer.print("{{-{c},--{s}}}", .{ param.short_name, param.long_name });
                        }

                        try writer.print("\"[{}]", .{std.zig.fmtEscapes(param.description)});
                    }

                    try writeType(writer, param.data);

                    try writer.writeAll("\"");

                    if (i < cmd.params.len - 1) {
                        try writer.writeAll(" \\\n");
                    }
                }

                try writer.writeAll("\n}\n\n");
            }

            try writer.writeAll("_gyro\n");
        }

        fn writeType(writer: anytype, comptime T: type) @TypeOf(writer).Error!void {
            switch (T) {
                void => return,
                Param.Directory => {
                    try writer.writeAll(": :_files -/");
                },
                Param.AnyFile => {
                    try writer.writeAll(": :_files");
                },
                Param.File => {
                    try writer.writeAll(": :_files -g '*.zig'");
                },
                Param.Package, Param.Repository => {
                    try writer.writeAll(": :_nothing");
                },

                else => {
                    switch (@typeInfo(T)) {
                        .Optional => |info| {
                            try writer.writeAll(":");
                            try writeType(writer, info.child);
                        },
                        .Enum => |info| {
                            try writer.writeAll(": :(");

                            inline for (info.fields) |field| {
                                try writer.print("'{s}' ", .{field.name});
                            }

                            try writer.writeAll(")");
                        },
                        else => @compileError("not implemented"),
                    }
                },
            }
        }
    };
};
