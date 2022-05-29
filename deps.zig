const std = @import("std");
const Pkg = std.build.Pkg;
const FileSource = std.build.FileSource;

pub const build_pkgs = struct {
    pub const mbedtls = @import(".gyro/zig-mbedtls-mattnite-github.com-a4f5357c/pkg/mbedtls.zig");
    pub const libgit2 = @import(".gyro/zig-libgit2-mattnite-github.com-0537beea/pkg/libgit2.zig");
    pub const libssh2 = @import(".gyro/zig-libssh2-mattnite-github.com-b5472a81/pkg/libssh2.zig");
    pub const zlib = @import(".gyro/zig-zlib-mattnite-github.com-eca7a5ba/pkg/zlib.zig");
    pub const libcurl = @import(".gyro/zig-libcurl-mattnite-github.com-f1f316dc/pkg/libcurl.zig");
};

pub const pkgs = struct {
    pub const version = Pkg{
        .name = "version",
        .source = FileSource{
            .path = ".gyro/version-mattnite-github.com-19baf08f/pkg/src/main.zig",
        },
    };

    pub const clap = Pkg{
        .name = "clap",
        .source = FileSource{
            .path = ".gyro/zig-clap-Hejsil-github.com-7188a9fc/pkg/clap.zig",
        },
    };

    pub const glob = Pkg{
        .name = "glob",
        .source = FileSource{
            .path = ".gyro/glob-mattnite-github.com-7d17d551/pkg/src/main.zig",
        },
    };

    pub const @"known-folders" = Pkg{
        .name = "known-folders",
        .source = FileSource{
            .path = ".gyro/known-folders-ziglibs-github.com-9db1b992/pkg/known-folders.zig",
        },
    };

    pub const tar = Pkg{
        .name = "tar",
        .source = FileSource{
            .path = ".gyro/tar-mattnite-github.com-92141da6/pkg/src/main.zig",
        },
    };

    pub const uri = Pkg{
        .name = "uri",
        .source = FileSource{
            .path = ".gyro/zig-uri-MasterQ32-github.com-e879df3a/pkg/uri.zig",
        },
    };

    pub const zzz = Pkg{
        .name = "zzz",
        .source = FileSource{
            .path = ".gyro/zzz-mattnite-github.com-564b924e/pkg/src/main.zig",
        },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        artifact.addPackage(pkgs.version);
        artifact.addPackage(pkgs.clap);
        artifact.addPackage(pkgs.glob);
        artifact.addPackage(pkgs.@"known-folders");
        artifact.addPackage(pkgs.tar);
        artifact.addPackage(pkgs.uri);
        artifact.addPackage(pkgs.zzz);
    }
};
