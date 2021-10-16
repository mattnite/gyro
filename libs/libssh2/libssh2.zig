const std = @import("std");

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

fn pathJoinRoot(comptime components: []const []const u8) []const u8 {
    var ret = root();
    inline for (components) |component|
        ret = ret ++ std.fs.path.sep_str ++ component;

    return ret;
}

const srcs = blk: {
    var ret = &.{
        pathJoinRoot(&.{ "c", "src", "channel.c" }),
        pathJoinRoot(&.{ "c", "src", "comp.c" }),
        pathJoinRoot(&.{ "c", "src", "crypt.c" }),
        pathJoinRoot(&.{ "c", "src", "hostkey.c" }),
        pathJoinRoot(&.{ "c", "src", "kex.c" }),
        pathJoinRoot(&.{ "c", "src", "mac.c" }),
        pathJoinRoot(&.{ "c", "src", "misc.c" }),
        pathJoinRoot(&.{ "c", "src", "packet.c" }),
        pathJoinRoot(&.{ "c", "src", "publickey.c" }),
        pathJoinRoot(&.{ "c", "src", "scp.c" }),
        pathJoinRoot(&.{ "c", "src", "session.c" }),
        pathJoinRoot(&.{ "c", "src", "sftp.c" }),
        pathJoinRoot(&.{ "c", "src", "userauth.c" }),
        pathJoinRoot(&.{ "c", "src", "transport.c" }),
        pathJoinRoot(&.{ "c", "src", "version.c" }),
        pathJoinRoot(&.{ "c", "src", "knownhost.c" }),
        pathJoinRoot(&.{ "c", "src", "agent.c" }),
        pathJoinRoot(&.{ "c", "src", "mbedtls.c" }),
        pathJoinRoot(&.{ "c", "src", "pem.c" }),
        pathJoinRoot(&.{ "c", "src", "keepalive.c" }),
        pathJoinRoot(&.{ "c", "src", "global.c" }),
        pathJoinRoot(&.{ "c", "src", "blowfish.c" }),
        pathJoinRoot(&.{ "c", "src", "bcrypt_pbkdf.c" }),
        pathJoinRoot(&.{ "c", "src", "agent_win.c" }),
    };

    break :blk ret;
};

const include_dir = pathJoinRoot(&.{ "c", "include" });
const config_dir = pathJoinRoot(&.{"config"});

pub fn link(
    b: *std.build.Builder,
    artifact: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
) !void {
    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        "-DLIBSSH2_MBEDTLS",
    });

    if (target.isWindows()) {
        try flags.appendSlice(&.{
            "-D_CRT_SECURE_NO_DEPRECATE=1",
            "-DHAVE_LIBCRYPT32",
            "-DHAVE_WINSOCK2_H",
            "-DHAVE_IOCTLSOCKET",
            "-DHAVE_SELECT",
            "-DLIBSSH2_DH_GEX_NEW=1",
        });

        if (target.getAbi().isGnu()) try flags.appendSlice(&.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_INTTYPES_H",
            "-DHAVE_SYS_TIME_H",
            "-DHAVE_GETTIMEOFDAY",
        });
    } else try flags.appendSlice(&.{
        "-DHAVE_UNISTD_H",
        "-DHAVE_INTTYPES_H",
        "-DHAVE_STDLIB_H",
        "-DHAVE_SYS_SELECT_H",
        "-DHAVE_SYS_UIO_H",
        "-DHAVE_SYS_SOCKET_H",
        "-DHAVE_SYS_IOCTL_H",
        "-DHAVE_SYS_TIME_H",
        "-DHAVE_SYS_UN_H",
        "-DHAVE_LONGLONG",
        "-DHAVE_GETTIMEOFDAY",
        "-DHAVE_INET_ADDR",
        "-DHAVE_POLL",
        "-DHAVE_SELECT",
        "-DHAVE_SOCKET",
        "-DHAVE_STRTOLL",
        "-DHAVE_SNPRINTF",
        "-DHAVE_O_NONBLOCK",
    });

    artifact.addIncludeDir(include_dir);
    artifact.addIncludeDir(config_dir);
    artifact.addCSourceFiles(srcs, flags.items);
    artifact.linkLibC();
}
