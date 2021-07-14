const std = @import("std");
pub const pkgs = struct {
    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = .{ .path = ".gyro/clap-mattnite-0.4.1-7a0b97b77100566ba997d45d0b88b0da/pkg/clap.zig" },
    };

    pub const zfetch = std.build.Pkg{
        .name = "zfetch",
        .path = .{ .path = ".gyro/zfetch-truemedian-0.1.4-d399ac2c94d41a878285c7a25b7070b1/pkg/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "network",
                .path = .{ .path = ".gyro/network-mattnite-0.0.3-8a04c54db48227831a0075774283b920/pkg/network.zig" },
            },
            std.build.Pkg{
                .name = "uri",
                .path = .{ .path = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg/uri.zig" },
            },
            std.build.Pkg{
                .name = "hzzp",
                .path = .{ .path = ".gyro/hzzp-truemedian-0.1.3-7678a4a8797ca7779a7c58159588b479/pkg/src/main.zig" },
            },
            std.build.Pkg{
                .name = "iguanaTLS",
                .path = .{ .path = ".gyro/iguanaTLS-alexnask-0d39a361639ad5469f8e4dcdaea35446bbe54b48/pkg/src/main.zig" },
            },
        },
    };

    pub const zzz = std.build.Pkg{
        .name = "zzz",
        .path = .{ .path = ".gyro/zzz-mattnite-0.0.2-d70873860188a3981735047775131887/pkg/src/main.zig" },
    };

    pub const glob = std.build.Pkg{
        .name = "glob",
        .path = .{ .path = ".gyro/glob-mattnite-0.0.0-aa0421127a95407237771b289dc32883/pkg/src/main.zig" },
    };

    pub const tar = std.build.Pkg{
        .name = "tar",
        .path = .{ .path = ".gyro/tar-mattnite-0.0.3-5248663420881895acdcbc377c865cbd/pkg/src/main.zig" },
    };

    pub const version = std.build.Pkg{
        .name = "version",
        .path = .{ .path = ".gyro/version-mattnite-0.1.0-9b361aca97d7dca883839d439b53c648/pkg/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "mecha",
                .path = .{ .path = ".gyro/mecha-Hejsil-2bde7ff18f0ce5d67a798df5aa1014f6eb4e9e14/pkg/mecha.zig" },
            },
        },
    };

    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = .{ .path = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg/uri.zig" },
    };

    pub const @"known-folders" = std.build.Pkg{
        .name = "known-folders",
        .path = .{ .path = ".gyro/known-folders-mattnite-0.0.1-27b7d8d0745583dc4848a638d0a42799/pkg/known-folders.zig" },
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

pub const exports = struct {
};
pub const base_dirs = struct {
    pub const clap = ".gyro/clap-mattnite-0.4.1-7a0b97b77100566ba997d45d0b88b0da/pkg";
    pub const zfetch = ".gyro/zfetch-truemedian-0.1.4-d399ac2c94d41a878285c7a25b7070b1/pkg";
    pub const zzz = ".gyro/zzz-mattnite-0.0.2-d70873860188a3981735047775131887/pkg";
    pub const glob = ".gyro/glob-mattnite-0.0.0-aa0421127a95407237771b289dc32883/pkg";
    pub const tar = ".gyro/tar-mattnite-0.0.3-5248663420881895acdcbc377c865cbd/pkg";
    pub const version = ".gyro/version-mattnite-0.1.0-9b361aca97d7dca883839d439b53c648/pkg";
    pub const uri = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg";
    pub const @"known-folders" = ".gyro/known-folders-mattnite-0.0.1-27b7d8d0745583dc4848a638d0a42799/pkg";
};
