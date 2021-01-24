const std = @import("std");
pub const pkgs = struct {
    pub const clap = std.build.Pkg{
        .name = "clap",
        .path = ".gyro/clap-gyro-0.4.0-775a546734a4b256657a427438723dd5/pkg/clap.zig",
    };

    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = ".gyro/hzzp-gyro-0.0.0-7a7057abc30140605b7b23260d9985aa/pkg/src/main.zig",
    };

    pub const zfetch = std.build.Pkg{
        .name = "zfetch",
        .path = ".gyro/zfetch-gyro-0.0.0-d1c25726c20a4a56c7327add393c8cd3/pkg/src/main.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "hzzp",
                .path = ".gyro/hzzp-gyro-0.0.0-7a7057abc30140605b7b23260d9985aa/pkg/src/main.zig",
            },
            std.build.Pkg{
                .name = "network",
                .path = ".gyro/network-gyro-0.0.0-c7c026240817cd74bcc3d4d99a094917/pkg/network.zig",
            },
            std.build.Pkg{
                .name = "uri",
                .path = ".gyro/uri-gyro-0.0.0-d7d6847747480b42d0bd79b5a01cc844/pkg/uri.zig",
            },
            std.build.Pkg{
                .name = "iguanatls",
                .path = ".gyro/iguanaTLS-gyro-0.0.0-6101a3d2308ac173845b016d8580b686/pkg/src/main.zig",
            },
        },
    };

    pub const zzz = std.build.Pkg{
        .name = "zzz",
        .path = ".gyro/zzz-gyro-0.0.0-87489da813d008978b78a01aad45754c/pkg/src/main.zig",
    };

    pub const glob = std.build.Pkg{
        .name = "glob",
        .path = ".gyro/glob-gyro-0.0.0-c278567a63b98d185a457938d3943ac0/pkg/src/main.zig",
    };

    pub const tar = std.build.Pkg{
        .name = "tar",
        .path = ".gyro/tar-gyro-0.0.0-7058911c82b28c7d4a09a42ccadc8561/pkg/src/main.zig",
    };

    pub const version = std.build.Pkg{
        .name = "version",
        .path = ".gyro/version-gyro-0.0.0-a6686b293cb8901859321a768a5811ad/pkg/src/main.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "mecha",
                .path = ".gyro/mecha-gyro-0.0.0-73989790133ba3dbd07cb87954587633/pkg/mecha.zig",
            },
        },
    };

    pub const uri = std.build.Pkg{
        .name = "uri",
        .path = ".gyro/uri-gyro-0.0.0-d7d6847747480b42d0bd79b5a01cc844/pkg/uri.zig",
    };


};

pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
    @setEvalBranchQuota(1_000_000);
    inline for (std.meta.declarations(pkgs)) |decl| {
        if (decl.is_pub and decl.data == .Var) {
            artifact.addPackage(@field(pkgs, decl.name));
        }
    }
}
