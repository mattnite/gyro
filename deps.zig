const std = @import("std");
pub const pkgs = struct {
    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = .{ .path = "libs/zig-clap/clap.zig" },
    };

    pub const zfetch = std.build.Pkg{
        .name = "zfetch",
        .path = .{ .path = "libs/zfetch/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            uri,
            std.build.Pkg{
                .name = "hzzp",
                .path = .{ .path = "libs/hzzp/src/main.zig" },
            },
            std.build.Pkg{
                .name = "network",
                .path = .{ .path = "libs/zig-network/network.zig" },
            },
            std.build.Pkg{
                .name = "iguanaTLS",
                .path = .{ .path = "libs/iguanaTLS/src/main.zig" },
            },
        },
    };

    pub const zzz = std.build.Pkg{
        .name = "zzz",
        .path = .{ .path = "libs/zzz/src/main.zig" },
    };

    pub const glob = std.build.Pkg{
        .name = "glob",
        .path = .{ .path = "libs/glob/src/main.zig" },
    };

    pub const tar = std.build.Pkg{
        .name = "tar",
        .path = .{ .path = "libs/tar/src/main.zig" },
    };

    pub const version = std.build.Pkg{
        .name = "version",
        .path = .{ .path = "libs/version/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "mecha",
                .path = .{ .path = "libs/mecha/mecha.zig" },
            },
        },
    };

    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = .{ .path = "libs/zig-uri/uri.zig" },
    };

    pub const @"known-folders" = std.build.Pkg{
        .name = "known-folders",
        .path = .{ .path = "libs/known-folders/known-folders.zig" },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};
