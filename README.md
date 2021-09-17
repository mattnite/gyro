<img align="left" width="200" height="200" src="img/logo.gif">

# gyro: a zig package manager

> A gyroscope is a device used for measuring or maintaining orientation

[![Linux](https://github.com/mattnite/gyro/workflows/Linux/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3ALinux) [![windows](https://github.com/mattnite/gyro/workflows/windows/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3Awindows) [![macOS](https://github.com/mattnite/gyro/workflows/macOS/badge.svg)](https://github.com/mattnite/gyro/actions?query=workflow%3AmacOS)

<br />

---

Table of contents
=================
* [Introduction](#introduction)
* [Installation](#installation)
  * [Building](#building)
* [How tos](#how-tos)
  * [Initialize project](#initialize-project)
    * [Setting up build.zig](#setting-up-buildzig)
    * [Ignoring gyro.lock](#ignoring-gyrolock)
  * [Export a package](#export-a-package)
  * [Publishing a package to astrolabe.pm](#publishing-a-package-to-astrolabepm)
  * [Adding dependencies](#adding-dependencies)
    * [From package index](#from-package-index)
    * [From Github](#from-github)
    * [From url](#from-url)
    * [Build dependencies](#build-dependencies)
    * [Scoped dependencies](#scoped-dependencies)
  * [Removing dependencies](#removing-dependencies)
  * [Local development](#local-development)
  * [Update dependencies -- for package consumers](#update-dependencies----for-package-consumers)
  * [Use gyro in Github Actions](#use-gyro-in-github-actions)
    * [Publishing from an action](#publishing-from-an-action)
  * [Completion Scripts](#completion-scripts)
* [Design philosophy](#design-philosophy)
* [Generated files](#generated-files)
  * [gyro.zzz](#gyrozzz)
  * [gyro.lock](#gyrolock)
  * [deps.zig](#depszig)
  * [./gyro/](#-gyro-)

## Introduction

Gyro is an unofficial package manager for the Zig programming language.  It
improves a developer's life by giving them a package experience similar to
cargo.  Dependencies are declared in a [gyro.zzz](#gyrozzz) file in the root of your
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
tarballs](https://github.com/mattnite/gyro/releases) for your system and add the
single static binary to your PATH. Gyro follows the master branch of the zig
compiler, if you are using zig version 0.8.1 or earlier you need to use gyro
0.2.3.

### Building

If you'd like to build from source, the only thing you need is the Zig compiler:

```
git clone --recursive https://github.com/mattnite/gyro.git
zig build -Drelease-safe
```

## How tos

Instead of just documenting all the different subcommands, this documentation
just lists out all the different scenarios that Gyro was built for. And if you
wanted to learn more about the cli you can simply `gyro <subcommand> --help`.

### Initialize project

If you have an existing project on Github that's a library then you can populate
[gyro.zzz](#gyrozzz) file with metadata:

```
gyro init <user>/<repo>
```

For both new and existing libraries you'd want to check out [export a
package](#export-a-package), if you don't plan on [publishing to
astrolabe](#publishing-a-package-to-astrolabepm) then ensuring the root file is
declared is all that's needed. For projects that are an executable or considered
the 'root' of the dependency tree, all you need to do is [add
dependencies](#adding-dependencies).

#### Setting up build.zig

In build.zig, the dependency tree can be imported with

```zig
const pkgs = @import("deps.zig").pkgs;
```

then in the build function all the packages can be added to an artifact with:

```zig
pkgs.addAllTo(lib);
```

individual packages exist in the pkgs namespace, so a package named `mecha` can
be individually added:

```zig
lib.addPackage(pkgs.mecha)
```

#### Ignoring gyro.lock

[gyro.lock](#gyrolock) is intended for reproducible builds. It is advised to add it to
`.gitignore` if your project is a library.

### Export a package

This operation doesn't have a cli equivalent so editing of [gyro.zzz](#gyrozzz)
is required, if you followed [initializing a project](#initialize-project) and
grabbed metadata from Github, then a lot of this work is done for you -- but
still probably needs some attention:

- the root file, it is `src/main.zig` by default
- the version
- file globs describing which files are actually part of the package. It is
  encouraged to include the license and readme.
- metadata: description, tags, source\_url, etc.
- [dependencies](#adding-dependencies)

### Publishing a package to astrolabe.pm

In order to publish to astrolabe you need a Github account and a browser. If
your project exports multiple packages you'll need to append the name, otherwise
you can simply:

```
gyro publish
```

This should open your browser to a page asking for a alphanumeric code which you
can find printed on the command line. Enter this code, this will open another
page to confirm read access to your user and your email from your Github
account. Once that is complete, Gyro will publish your package and if successful
a link to it will be printed to stdout.

An access token is cached so that this browser sign-on process only needs to be
done once for a given dev machine.

If you'd like to add publishing from a CI system see [Publishing from an
action](#publishing-from-an-action).

### Adding dependencies

#### From package index

```
gyro add <user>/<pkg>
```

#### From Github

```
gyro add --src github <user>/<repo>
```

#### From url
Note that at this time it is not possible to add a dependency from a url using
the command line. However, it is possible to give a url to a .tar.gz file by
adding it to your `gyro.zzz` file.
```yaml
deps:
  pkgname:
    src:
      url: "https://path/to/my/library.tar.gz"
    root: libname/rootfile.zig
```
In this example, when `library.tar.gz` is extracted the top level directory is
`libname`. In practice one can construct a gyro.zzz file which will get a source
tarball from many hosting sites other than github, by carefully constructing the
url and path to the library root.
```yaml
deps:
// Gitlab example
  foo:
    src:
      // Gitlab tarballs follow the format "project-branch.tar.gz" or
      // "project-tag.tar.gz".
      url: "https://gitlab.com/username/foo/-/archive/main/foo-main.tar.gz"
    // The tarball will extract to the top level directory "project-branch/"
    root: foo-main/main.zig
// Codeberg (Gitea)
  bar:
    src:
      // Gitea omits the project name from it's tarballs, using just the branch
      // or tag name.
      url: "https://codeberg.org/username/bar/archive/main.tar.gz"
    root: bar/main.zig
```

#### Build dependencies

It's also possible to use packaged code in your `build.zig`, since this would
only run at build time and not required in your application or library these are
kept separate from your regular dependencies in your project file.

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
const zzz = @import("zzz");

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("main", "src/main.zig");
    pkgs.addAllTo(exe);
    exe.install();

    // maybe do some workflow based on gyro.zzz
    var tree = zzz.ZTree(1, 100){};
    ...
}
```

#### Scoped dependencies

Dependencies added to a project are dependencies of all exported packages. In
some cases you might want to add a dependency to only one package, and this can
be done with the `--to` argument:

```
gyro add alexnask/iguanaTLS --to some_package
```

Build dependecies cannot be scoped to an exported package because build
dependencies only affect the current project.

### Removing dependencies

Removing a dependency only requires the alias (string used to import):

```
gyro remove iguanaTLS
```

Removing [scoped dependencies](#scoped-dependencies) requires the `--from`
argument:

```
gyro remove iguanaTLS --from some_package
```

### Local development

One can switch out a dependency for a local copy using the `redirect`
subcommand. Let's say we're using `mattnite/tar` from astrolabe and we come
across a bug, we can debug with a local version of the package by running:

```
gyro redirect -a tar -p ../tar
```

This will point gyro at your local copy, and when you're done you can revert the
redirect(s) with:

```
gyro redirect --clean
```

Multiple dependencies can be redirected. Build dependencies are redirected by
passing `-b`. You can even redirect the dependencies of a local package.

HOT tip: add this to your git `pre-commit` hook to catch you before accidentally
commiting redirects:

```
gyro redirect --check
```

### Update dependencies -- for package consumers

Updating dependencies only works for package consumers as it modifies
[gyro.lock](#gyrolock). It does not change dependency requirements, merely resolves the
dependencies to their latest versions. Simply:

```
gyro update
```

Updating single dependencies will come soon, right now everything is updated.

### Use gyro in Github Actions

You can get your hands on Gyro for github actions
[here](https://github.com/marketplace/actions/setup-gyro), it does not install
the zig compiler so remember to include that as well!

#### Publishing from an action

It's possible to publish your package in an action or other CI system. If the
environment variable `GYRO_ACCESS_TOKEN` exists, Gyro will use that for the
authenticated publish request instead of using Github's device flow. For Github
actions this requires [creating a personal access
token](https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token)
with scope `read:user` and `user:email` and [adding it to an
Environment](https://docs.github.com/en/actions/reference/encrypted-secrets#creating-encrypted-secrets-for-a-repository),
and adding that Environment to your job. This allows you to access your token in
the `secrets` namespace. Here's an example publish job:

```yaml
name: Publish

on: workflow_dispatch

jobs:
  publish:
    runs-on: ubuntu-latest
    environment: publish
    steps:
      - uses: mattnite/setup-gyro@v1
      - uses: actions/checkout@v2
      - run: gyro publish
        env:
          GYRO_ACCESS_TOKEN: ${{ secrets.GYRO_ACCESS_TOKEN }}
```

### Completion Scripts

Completion scripts can be generated by the `completion` subcommand, it is run
like so:

```
gyro completion -s <shell> <install path>
```

Right now only `zsh` is the only supported shell, and this will create a `_gyro`
file in the install path. If you are using `oh-my-zsh` then this path should be
`$HOME/.oh-my-zsh/completions`.

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
astrolabe.pm](#publishing-a-package-to-astrolabepm), as well as local
development.

Similar to how the Zig compiler is meant to be dependency 0, gyro is intended to
work as dependency 1. This means that there are no runtime dependencies, (Eg.
git), and no dynamic libraries. Instead of statically linking to every VCS
library in existence, the more strategic route was to instead use tarballs
(tar.gz) for everything. The cost of this approach is that not every repository
is accessible, however:

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

This is your project file, it contains the packages you export (if any),
dependencies, and build dependencies. `zzz` is a file format similar to yaml but
has a stricter spec and is implemented in zig.

A map of a gyro.zzz file looks something like this:
```yaml
pkgs:
  pkg_a:
    version: 0.0.0
    description: the description field
    license: spdix-id
    homepage_url: https://straight.forward
    sourse_url: https://straight.forward

    # these are shown on astrolabe
    tags:
      http
      cli

    # allows for globbing, doesn't do recursive globbing yet
    files:
      LICENSE
      README.md # this is displayed on the astrolabe
      build.zig
      src/*.zig

    # scoped dependencies, look the same as root deps
    deps:
      ...

  # exporting a second package
  pkg_b:
    version: 0.0.0
    ...

# like 'deps' but these can be directly imported in build.zig
build_deps:
  ...

# most 'keys' are the string used to import in zig code, the exception being
# packages from the default package index which have a shortend version
deps:
  # a package from the default package index, user is 'bruh', its name is 'blarg'
  # and is imported with the same string
  bruh/blarg: ^0.1.0

  # importing blarg from a different package index, have to use a different
  # import string, I'll use 'flarp'
  flarp:
    src:
      pkg:
        name: blarg
        user: arst
        version: ^0.3.0
        repository: something.gg

  # a github package, imported with string 'mecha'
  mecha:
    root: mecha.zig
    src:
      github:
        user: Hejsil
        repo: mecha
        ref: zig-master

  # a raw url, imported with string 'raw' (remember its gotta be a tar.gz)
  raw:
    root: bar.zig
    src: url: "https://example.com/foo.tar.gz"
```

### gyro.lock

This contains a lockfile for reproducible builds, it is only useful in compiled
projects, not libraries. Adding gyro.lock to your package will not affect
resolved versions of dependencies for your users -- it is suggested to add this
file to your `.gitignore` for libraries.

### deps.zig

This is the generated file that's imported by `build.zig`, it can be imported
with `@import("deps.zig")` or `@import("gyro")`. Unless you are vendoring your
dependencies, this should be added to `.gitignore`.

### .gyro/

This directory holds the source code of all your dependencies. Path names are
human readable and look something like `<package>-<user>-<hash>` so in many
cases it is possible to navigate to dependencies and make small edits if you run
into bugs. For a more robust way to edit dependencies see [local
development](#local-development)

It is suggested to add this to `.gitignore` as well.
