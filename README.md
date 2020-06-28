# Zkg: a Zig Package Manager

This project is merely a prototype exploring a simple packaging use case for
zig, and that's including source from zig-only projects in git repositories. It
has a lot of limitiations right now, such as `https` only repos and only first
order dependencies (no dependencies of dependencies) as it's only a prototype
and I want to get feedback from the community.

## Methodology

To quote Andrew:

```
In summary, Zig's package manager will be a glorified downloading tool, that
provides analysis and details to help the human perform the social process of
choosing what set of other people's code to rely on, but without any central
appeal to authority.
```
[reference](https://github.com/ziglang/zig/issues/943#issuecomment-586386891)

And zkg is exactly that. We parse an `imports.zig` file that you place in the
root directory of your project, fetch the packages described using `libgit2`,
then generate a `packages.zig` file in `zig-cache` that exports an array of
`std.build.Pkg`.  These `Pkgs` can then be used in `build.zig`.

## Example

This example can be found [here](https://github.com/matt1795/zkg-example). To
get started you need to set an environment variable `ZKG_CACHE` which is where
all the fetched repositories go, I set mine to `~/.cache/zkg`.

`zkg-example` is a program that uses
[zig-clap](https://github.com/Hejsil/zig-clap) (Thank you Hejsil for making an
awesome library) to parse arguments that will be concatenated with
[concat](https://github.com/matt1795/concat) -- a dummy library I made.

Here is the `imports.zig`:

```zig

const zkg = @import("zkg");

pub const clap = zkg.import.git(
    "https://github.com/Hejsil/zig-clap.git",
    "master",
    "clap.zig",
);

pub const test_lib = zkg.import.git(
    "https://github.com/matt1795/concat.git",
    "master",
    null,
);
```

### IMPORTANT NOTE
zkg's zig interpretation is a complete sham at this point -- again just getting
things working here. It only checks for public const variable declarations that
are initialized with a function having three parameters. It assumes the function
is `zig.import.git()`.

The arguments for `zig.import.git()` are the url of the repo, the branch, and
optionally you may tell zkg what the root file you want to include as the base
of the package. If null is given zkg will look for a file called `exports.zig`
in the root of the dependency.

The name of the exported variable is important because it will be the string
that you use in your application code to `@import` the package. Eg:

```zig
const my_lib = @import("test_lib");
```

Run zkg in your project root to generate the `packages.zig` file (too simple to
have arguments right now), the contents will look like this:

```zig
const std = @import("std");
const Pkg = std.build.Pkg;

pub const list = [_]Pkg{
    Pkg{
        .name = "clap",
        .path = "/home/mknight/.cache/zkg/github.com/Hejsil/zig-clap/master/clap.zig",
        .dependencies = null,
    },
    Pkg{
        .name = "test_lib",
        .path = "/home/mknight/.cache/zkg/github.com/matt1795/concat/master/exports.zig",
        .dependencies = null,
    },
};
```

And here is `build.zig` where we add the `Pkg`s to our project:

```zig
const Builder = @import("std").build.Builder;
const packages = @import("zig-cache/packages.zig").list;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zkg-example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    for (packages) |pkg| {
        exe.addPackage(pkg);
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```
