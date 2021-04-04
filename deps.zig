const std = @import("std");
pub const pkgs = struct {
    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = ".gyro/clap-mattnite-0.4.0-54d7cbbdb9bc1d8a78583857764d0888/pkg/clap.zig",
    };

    pub const zfetch = std.build.Pkg{
        .name = "zfetch",
        .path = ".gyro/zfetch-truemedian-0.0.2-dd0562001638038c5db9417734768032/pkg/src/main.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "iguanaTLS",
                .path = ".gyro/iguanaTLS-alexnask-0.0.1-37c1311658622b9a68d1b5793c078531/pkg/src/main.zig",
            },
            std.build.Pkg{
                .name = "network",
                .path = ".gyro/network-mattnite-0.0.1-56b1687581a638461a2847c093576538/pkg/network.zig",
            },
            std.build.Pkg{
                .name = "uri",
                .path = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg/uri.zig",
            },
            std.build.Pkg{
                .name = "hzzp",
                .path = ".gyro/hzzp-truemedian-0.0.2-4888b8d09a0d5cca27871c42328a74a7/pkg/src/main.zig",
            },
        },
    };

    pub const zzz = std.build.Pkg{
        .name = "zzz",
        .path = ".gyro/zzz-mattnite-0.0.1-549813427325d6937837db763750658a/pkg/src/main.zig",
    };

    pub const glob = std.build.Pkg{
        .name = "glob",
        .path = ".gyro/glob-mattnite-0.0.0-aa0421127a95407237771b289dc32883/pkg/src/main.zig",
    };

    pub const tar = std.build.Pkg{
        .name = "tar",
        .path = ".gyro/tar-mattnite-0.0.1-0584a099318b69726aa5c99c7d15c58b/pkg/src/main.zig",
    };

    pub const version = std.build.Pkg{
        .name = "version",
        .path = ".gyro/version-mattnite-0.0.0-071bc17b548751447d1a3a39307c9593/pkg/src/main.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "mecha",
                .path = ".gyro/mecha-mattnite-0.0.1-47b82d9146d42cb9505ac7317488271b/pkg/mecha.zig",
            },
        },
    };

    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg/uri.zig",
    };

    pub const @"known-folders" = std.build.Pkg{
        .name = "known-folders",
        .path = ".gyro/known-folders-mattnite-0.0.0-a10b67a6d7187957d537839131b9d1b6/pkg/known-folders.zig",
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

pub const base_dirs = struct {
    pub const clap = ".gyro/clap-mattnite-0.4.0-54d7cbbdb9bc1d8a78583857764d0888/pkg";
    pub const zfetch = ".gyro/zfetch-truemedian-0.0.2-dd0562001638038c5db9417734768032/pkg";
    pub const zzz = ".gyro/zzz-mattnite-0.0.1-549813427325d6937837db763750658a/pkg";
    pub const glob = ".gyro/glob-mattnite-0.0.0-aa0421127a95407237771b289dc32883/pkg";
    pub const tar = ".gyro/tar-mattnite-0.0.1-0584a099318b69726aa5c99c7d15c58b/pkg";
    pub const version = ".gyro/version-mattnite-0.0.0-071bc17b548751447d1a3a39307c9593/pkg";
    pub const uri = ".gyro/uri-mattnite-0.0.0-b13185702852c80a6772a8d1bda35496/pkg";
    pub const @"known-folders" = ".gyro/known-folders-mattnite-0.0.0-a10b67a6d7187957d537839131b9d1b6/pkg";
};
