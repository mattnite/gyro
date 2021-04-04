<img align="left" width="200" height="200" src="img/logo.gif">

# gyro: a zig package manager

> A gyroscope is a device used for measuring or maintaining orientation

[![Linux](https://github.com/mattnite/gyro/workflows/Linux/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3ALinux) [![windows](https://github.com/mattnite/gyro/workflows/windows/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3Awindows) [![macOS](https://github.com/mattnite/gyro/workflows/macOS/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3AmacOS)

<br />

---

Table of Contents
=================
  * [Introduction](#introduction)
  * [Installation](#installation)
    * [Building](#building)
  * [How tos](#how-tos)
    * [Initialize project](#initialize-project)
      * [Existing project](#existing-project)
    * [Produce a Package](#produce-a-package)
      * [Export multiple packages](#export-multiple-packages)
    * [Publishing a package to astrolabe.pm](#publishing-a-package-to-astrolabepm)
    * [Adding dependencies](#adding-dependencies)
      * [From package index](#from-package-index)
      * [From Github](#from-github)
      * [From raw url (tar.gz)](#from-raw-url)
      * [Build dependencies](#build-dependencies)
      * [Scoped dependencies](#scoped-dependencies)
      * [Remove dependency via cli](#remove-dependency-via-cli)
    * [Building your project](#building-your-dependency)
    * [Local development](#local-development)
    * [Update dependencies -- for package consumers](#update-dependencies)
    * [Package C Libraries](#package-c-libraries)
    * [Use gyro in github actions](#use-gyro-in-github-actions)
  * [Design philosophy](#design-philosophy)
  * [Generated files](#generated-files)
    * [gyro.zzz](#gyrozzz)
    * [gyro.lock](#gyrolock)
    * [deps.zig](#depszig)
    * [.gyro/](#gyro)

## Introduction

Gyro is an unofficial package manager for the Zig programming language.  It
improves a developer's life by giving them a package experience similar to
cargo.  Dependencies are declared in a `gyro.zzz` file in the root of your
project, and are exposed to you programmatically in the `build.zig` file by
importing `@import("deps.zig").pkgs`.  In short, all that's needed on your part
is how you want to add packages to different objects you're building:

```zig
const Builder = @import("std").build.Builder;
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("main", "src/main.zig");
    pkgs.addAllTo(exe);
    exe.install();
}
```

To make the job of finding suitable packages to use in your project easier,
gyro is paired with a package index located at
[astrolabe.pm](https://astrolabe.pm).  A simple `gyro add alexnask/iguanaTLS`
will add the latest version of `iguanaTLS` (pure Zig TLS library) as a
dependency.  To build your project all that's needed is `gyro build` which
works exactly like `zig build`, you can append the same arguments, except it
automatically downloads any missing dependencies.  To learn about other If you
want to use a dependency from github, you can add it by explicitly with `github
add -s github <user>/<repo> [<ref>]`.  `<ref>` is an optional arg which can be
a branch, tag, or commit hash, if not specified, gyro uses the default branch.

## Installation

In order to install gyro, all you need to do is extract one of the [release
tarballs](https://github.com/mattnite/gyro/releases) for your system and add
the single static binary to your PATH.

### Building

If you'd like to build from source, the only thing you need is the Zig compiler:

```
git clone --recursive https://github.com/mattnite/gyro.git
zig build -Dbootstrap
```

The `-Dbootstrap` is required because gyro uses git submodules to do the
initial build.  After that one can build gyro with gyro, this will pull
packages from the package index instead of using git submodules.

```
gyro build
```

(Note: you might need to move the original gyro binary from the `zig-cache`
first).  This command wraps `zig build`, so you can pass arguements like you
normally would, like `gyro build test` to run your unit tests.


## How tos

Instead of just documenting all the different subcommands, this documentation
just lists out all the different scenarios that Gyro was built for. And if you
wanted to learn more about the cli you can simply `gyro <subcommand> --help`.

### Initialize project

The easiest way for an existing project to adopt gyro is to start by running
`gyro init <user>/<repo>` to grab metadata from their Github project.  From
there the package maintainer to finish the init process by defining a few more
things:

- the root file, it is `src/main.zig` by default
- file globs describing which files are actually part of the package. It is
  encouraged to include the license and readme, as well as testing code.
- any other packages if the repo exports multiple repos (and their
  corresponding root files of course)
- dependencies (see previous section).

#### Existing project

### Export a package

#### Export multiple packages

### Publishing a package to astrolabe.pm

### Adding dependencies

To find potential Zig packages you'd like to use:
- [astrolabe.pm](https://astrolabe.pm), the default package index
- [zpm](https://zpm.random-projects.net), a site that lists cool Zig projects
  and where to find them
- search github for `#zig` and `#zig-package` tags

If you want to use code from a package from astrolabe, then all you need to do
is `gyro add <user>/<package>`, else if you want to use a Github repository as a
dependency then all that's required is `gyro add --src github <user>/<repo>`.

Packages are exposed to your `build.zig` file through a struct in
`@import("deps.zig")`, and you can simply add them using a `addAllTo()` function,
and then `@import()` in your code.

Assume there is a `hello_world` package available on the index, published by
`some_user` we'd add it to our project like so:

```
gyro add some_user/hello_world
```

build.zig:

```zig
const Builder = @import("std").build.Builder;
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("main", "src/main.zig");
    pkgs.addAllTo(exe);
    exe.install();
}
``` 

main.zig:

```zig
const hw = @import("hello_world");

pub fn main() !void {
    try hw.greet();
}
```

If you want to "link" a specific package to an object, the packages you depend
on are accessed like `pkgs.<package name>` so in the example above you could
instead do `exe.addPackage(pkgs.hello_world)`.


#### From package index

#### From Github

#### From raw url (tar.gz)

#### Build dependencies

It's also possible to use packaged code in your `build.zig`, since this would
only run at build time and most likely not required in your application or
library these are kept separate from your regular dependencies in your project
file.

When you want to add a dependency as a build dep, all you need to do is add
`--build-dep` to the gyro invocation.  For example, let's assume I need to do
some parsing with a package called `mecha`:

```
gyro add --build-dep mattnite/zzz
```

and in my `build.zig`:

```zig
const Builder = @import("std").build.Builder;
const pkgs = @import("gyro").pkgs;
const mecha = @import("mecha");

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("main", "src/main.zig");
    pkgs.addAllTo(exe);
    exe.install();
}
```

#### Scoped dependencies

### Removing dependencies

### Local development

### Update dependencies -- for package consumers

### C libraries

### Use gyro in Github Actions 

You can get your hands on Gyro for github actions
[here](https://github.com/marketplace/actions/setup-gyro), it does not install
the zig compiler so remember to include that as well!

## Design philosophy

The two main obectives for gyro are providing a great user experience and
creating a platform for members of the community to get their hands dirty with
Zig package management. The hope here is that this experience will better
inform the development of the official package manager.

To create a great user experience, gyro is inspired by Rust's package manager,
Cargo. It does this by taking over the build runner so that `zig build` is
effectively replaced with `gyro build`, and this automatically downloads missing
dependencies and allows for [build dependencies](#build-dependencies). Other
features include easy [addition of dependencies](#adding-dependencies) through
the cli, [publishing packages on
astrolabe.pm](#publishing-a-package-to-astrolabepm), as well as local development.

Similar to how the Zig compiler is meant to be dependency 0, gyro is intended to
work as dependency 1. This means that there are no runtime dependencies, (Eg.
git), and no dynamic libraries. Instead of statically linking to every VCS
library in existence, the more strategic route was to instead use tarballs
(tar.gz) for everything. The cost of this approach is that not every
repository is accessible, however:

- Most projects release source in a tarball (think C libraries here)
- Github's api allows for downloading a tarball for a repo given a commit, tag,
  or branch
- Gyro's packaging system uses tarballs
- Stdlib has gzip decompression
- Easy to keep Gyro as a pure Zig codebase (no cross compilation pains)

It lifts a considerable amount of work off the project in order to focus on the
two main objectives while covering most codebases. 

The official Zig package manager is going to be decentralized, meaning that
there will be no official package index. Gyro has a centralized feel in that the
best UX is to use Astrolabe, but you can use it without interacting with the
package index. It again comes down to not spending effort on supporting
everything imaginable, and instead focus on experimenting with big design
decisions around package management.

## Generated files

### gyro.zzz

### gyro.lock

### deps.zig

### ./gyro/
