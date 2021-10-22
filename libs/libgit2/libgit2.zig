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
    @setEvalBranchQuota(5000);
    var ret = &.{
        pathJoinRoot(&.{ "c", "deps", "http-parser", "http_parser.c" }),
        pathJoinRoot(&.{ "c", "src", "allocators", "failalloc.c" }),
        pathJoinRoot(&.{ "c", "src", "allocators", "stdalloc.c" }),
        pathJoinRoot(&.{ "c", "src", "streams", "openssl.c" }),
        pathJoinRoot(&.{ "c", "src", "streams", "registry.c" }),
        pathJoinRoot(&.{ "c", "src", "streams", "socket.c" }),
        pathJoinRoot(&.{ "c", "src", "streams", "tls.c" }),
        pathJoinRoot(&.{"mbedtls.c"}),
        pathJoinRoot(&.{ "c", "src", "transports", "auth.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "credential.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "http.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "httpclient.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "smart_protocol.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "ssh.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "git.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "smart.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "smart_pkt.c" }),
        pathJoinRoot(&.{ "c", "src", "transports", "local.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xdiffi.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xemit.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xhistogram.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xmerge.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xpatience.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xprepare.c" }),
        pathJoinRoot(&.{ "c", "src", "xdiff", "xutils.c" }),
        pathJoinRoot(&.{ "c", "src", "hash", "sha1", "mbedtls.c" }),
        pathJoinRoot(&.{ "c", "src", "alloc.c" }),
        pathJoinRoot(&.{ "c", "src", "annotated_commit.c" }),
        pathJoinRoot(&.{ "c", "src", "apply.c" }),
        pathJoinRoot(&.{ "c", "src", "attr.c" }),
        pathJoinRoot(&.{ "c", "src", "attrcache.c" }),
        pathJoinRoot(&.{ "c", "src", "attr_file.c" }),
        pathJoinRoot(&.{ "c", "src", "blame.c" }),
        pathJoinRoot(&.{ "c", "src", "blame_git.c" }),
        pathJoinRoot(&.{ "c", "src", "blob.c" }),
        pathJoinRoot(&.{ "c", "src", "branch.c" }),
        pathJoinRoot(&.{ "c", "src", "buffer.c" }),
        pathJoinRoot(&.{ "c", "src", "cache.c" }),
        pathJoinRoot(&.{ "c", "src", "checkout.c" }),
        pathJoinRoot(&.{ "c", "src", "cherrypick.c" }),
        pathJoinRoot(&.{ "c", "src", "clone.c" }),
        pathJoinRoot(&.{ "c", "src", "commit.c" }),
        pathJoinRoot(&.{ "c", "src", "commit_graph.c" }),
        pathJoinRoot(&.{ "c", "src", "commit_list.c" }),
        pathJoinRoot(&.{ "c", "src", "config.c" }),
        pathJoinRoot(&.{ "c", "src", "config_cache.c" }),
        pathJoinRoot(&.{ "c", "src", "config_entries.c" }),
        pathJoinRoot(&.{ "c", "src", "config_file.c" }),
        pathJoinRoot(&.{ "c", "src", "config_mem.c" }),
        pathJoinRoot(&.{ "c", "src", "config_parse.c" }),
        pathJoinRoot(&.{ "c", "src", "config_snapshot.c" }),
        pathJoinRoot(&.{ "c", "src", "crlf.c" }),
        pathJoinRoot(&.{ "c", "src", "date.c" }),
        pathJoinRoot(&.{ "c", "src", "delta.c" }),
        pathJoinRoot(&.{ "c", "src", "describe.c" }),
        pathJoinRoot(&.{ "c", "src", "diff.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_driver.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_file.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_generate.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_parse.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_print.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_stats.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_tform.c" }),
        pathJoinRoot(&.{ "c", "src", "diff_xdiff.c" }),
        pathJoinRoot(&.{ "c", "src", "errors.c" }),
        pathJoinRoot(&.{ "c", "src", "fetch.c" }),
        pathJoinRoot(&.{ "c", "src", "fetchhead.c" }),
        pathJoinRoot(&.{ "c", "src", "filebuf.c" }),
        pathJoinRoot(&.{ "c", "src", "filter.c" }),
        pathJoinRoot(&.{ "c", "src", "futils.c" }),
        pathJoinRoot(&.{ "c", "src", "graph.c" }),
        pathJoinRoot(&.{ "c", "src", "hash.c" }),
        pathJoinRoot(&.{ "c", "src", "hashsig.c" }),
        pathJoinRoot(&.{ "c", "src", "ident.c" }),
        pathJoinRoot(&.{ "c", "src", "idxmap.c" }),
        pathJoinRoot(&.{ "c", "src", "ignore.c" }),
        pathJoinRoot(&.{ "c", "src", "index.c" }),
        pathJoinRoot(&.{ "c", "src", "indexer.c" }),
        pathJoinRoot(&.{ "c", "src", "iterator.c" }),
        pathJoinRoot(&.{ "c", "src", "libgit2.c" }),
        pathJoinRoot(&.{ "c", "src", "mailmap.c" }),
        pathJoinRoot(&.{ "c", "src", "merge.c" }),
        pathJoinRoot(&.{ "c", "src", "merge_driver.c" }),
        pathJoinRoot(&.{ "c", "src", "merge_file.c" }),
        pathJoinRoot(&.{ "c", "src", "message.c" }),
        pathJoinRoot(&.{ "c", "src", "midx.c" }),
        pathJoinRoot(&.{ "c", "src", "mwindow.c" }),
        pathJoinRoot(&.{ "c", "src", "net.c" }),
        pathJoinRoot(&.{ "c", "src", "netops.c" }),
        pathJoinRoot(&.{ "c", "src", "notes.c" }),
        pathJoinRoot(&.{ "c", "src", "object_api.c" }),
        pathJoinRoot(&.{ "c", "src", "object.c" }),
        pathJoinRoot(&.{ "c", "src", "odb.c" }),
        pathJoinRoot(&.{ "c", "src", "odb_loose.c" }),
        pathJoinRoot(&.{ "c", "src", "odb_mempack.c" }),
        pathJoinRoot(&.{ "c", "src", "odb_pack.c" }),
        pathJoinRoot(&.{ "c", "src", "offmap.c" }),
        pathJoinRoot(&.{ "c", "src", "oidarray.c" }),
        pathJoinRoot(&.{ "c", "src", "oid.c" }),
        pathJoinRoot(&.{ "c", "src", "oidmap.c" }),
        pathJoinRoot(&.{ "c", "src", "pack.c" }),
        pathJoinRoot(&.{ "c", "src", "pack-objects.c" }),
        pathJoinRoot(&.{ "c", "src", "parse.c" }),
        pathJoinRoot(&.{ "c", "src", "patch.c" }),
        pathJoinRoot(&.{ "c", "src", "patch_generate.c" }),
        pathJoinRoot(&.{ "c", "src", "patch_parse.c" }),
        pathJoinRoot(&.{ "c", "src", "path.c" }),
        pathJoinRoot(&.{ "c", "src", "pathspec.c" }),
        pathJoinRoot(&.{ "c", "src", "pool.c" }),
        pathJoinRoot(&.{ "c", "src", "pqueue.c" }),
        pathJoinRoot(&.{ "c", "src", "proxy.c" }),
        pathJoinRoot(&.{ "c", "src", "push.c" }),
        pathJoinRoot(&.{ "c", "src", "reader.c" }),
        pathJoinRoot(&.{ "c", "src", "rebase.c" }),
        pathJoinRoot(&.{ "c", "src", "refdb.c" }),
        pathJoinRoot(&.{ "c", "src", "refdb_fs.c" }),
        pathJoinRoot(&.{ "c", "src", "reflog.c" }),
        pathJoinRoot(&.{ "c", "src", "refs.c" }),
        pathJoinRoot(&.{ "c", "src", "refspec.c" }),
        pathJoinRoot(&.{ "c", "src", "regexp.c" }),
        pathJoinRoot(&.{ "c", "src", "remote.c" }),
        pathJoinRoot(&.{ "c", "src", "repository.c" }),
        pathJoinRoot(&.{ "c", "src", "reset.c" }),
        pathJoinRoot(&.{ "c", "src", "revert.c" }),
        pathJoinRoot(&.{ "c", "src", "revparse.c" }),
        pathJoinRoot(&.{ "c", "src", "revwalk.c" }),
        pathJoinRoot(&.{ "c", "src", "runtime.c" }),
        pathJoinRoot(&.{ "c", "src", "signature.c" }),
        pathJoinRoot(&.{ "c", "src", "sortedcache.c" }),
        pathJoinRoot(&.{ "c", "src", "stash.c" }),
        pathJoinRoot(&.{ "c", "src", "status.c" }),
        pathJoinRoot(&.{ "c", "src", "strarray.c" }),
        pathJoinRoot(&.{ "c", "src", "strmap.c" }),
        pathJoinRoot(&.{ "c", "src", "submodule.c" }),
        pathJoinRoot(&.{ "c", "src", "sysdir.c" }),
        pathJoinRoot(&.{ "c", "src", "tag.c" }),
        pathJoinRoot(&.{ "c", "src", "thread.c" }),
        pathJoinRoot(&.{ "c", "src", "threadstate.c" }),
        pathJoinRoot(&.{ "c", "src", "trace.c" }),
        pathJoinRoot(&.{ "c", "src", "trailer.c" }),
        pathJoinRoot(&.{ "c", "src", "transaction.c" }),
        pathJoinRoot(&.{ "c", "src", "transport.c" }),
        pathJoinRoot(&.{ "c", "src", "tree.c" }),
        pathJoinRoot(&.{ "c", "src", "tree-cache.c" }),
        pathJoinRoot(&.{ "c", "src", "tsort.c" }),
        pathJoinRoot(&.{ "c", "src", "utf8.c" }),
        pathJoinRoot(&.{ "c", "src", "util.c" }),
        pathJoinRoot(&.{ "c", "src", "varint.c" }),
        pathJoinRoot(&.{ "c", "src", "vector.c" }),
        pathJoinRoot(&.{ "c", "src", "wildmatch.c" }),
        pathJoinRoot(&.{ "c", "src", "worktree.c" }),
        pathJoinRoot(&.{ "c", "src", "zstream.c" }),
    };

    break :blk ret;
};

const zlib_srcs = &.{
    pathJoinRoot(&.{ "c", "deps", "zlib", "adler32.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "crc32.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "deflate.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "infback.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "inffast.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "inflate.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "inftrees.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "trees.c" }),
    pathJoinRoot(&.{ "c", "deps", "zlib", "zutil.c" }),
};

const pcre_srcs = &.{
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_byte_order.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_chartables.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_compile.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_config.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_dfa_exec.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_exec.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_fullinfo.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_get.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_globals.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_jit_compile.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_maketables.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_newline.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_ord2utf8.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcreposix.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_printint.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_refcount.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_string_utils.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_study.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_tables.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_ucd.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_valid_utf8.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_version.c" }),
    pathJoinRoot(&.{ "c", "deps", "pcre", "pcre_xclass.c" }),
};

const posix_srcs = &.{
    pathJoinRoot(&.{ "c", "src", "posix.c" }),
};

const unix_srcs = &.{
    pathJoinRoot(&.{ "c", "src", "unix", "map.c" }),
    pathJoinRoot(&.{ "c", "src", "unix", "realpath.c" }),
};

const win32_srcs = &.{
    pathJoinRoot(&.{ "c", "src", "win32", "dir.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "error.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "findfile.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "map.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "path_w32.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "posix_w32.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "precompiled.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "thread.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "utf-conv.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "w32_buffer.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "w32_leakcheck.c" }),
    pathJoinRoot(&.{ "c", "src", "win32", "w32_util.c" }),
};

pub fn link(
    b: *std.build.Builder,
    artifact: *std.build.LibExeObjStep,
) !void {
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();

    try flags.appendSlice(&.{
        "-DLIBGIT2_NO_FEATURES_H",
        "-DGIT_TRACE=1",
        "-DGIT_THREADS=1",
        "-DGIT_USE_FUTIMENS=1",
        "-DGIT_REGEX_PCRE",
        "-DGIT_SSH=1",
        "-DGIT_SSH_MEMORY_CREDENTIALS=1",
        "-DGIT_HTTPS=1",
        "-DGIT_MBEDTLS=1",
        "-DGIT_SHA1_MBEDTLS=1",
    });

    if (64 == artifact.target.getCpuArch().ptrBitWidth())
        try flags.append("-DGIT_ARCH_64=1");

    artifact.addCSourceFiles(srcs, flags.items);
    if (artifact.target.isWindows()) {
        try flags.appendSlice(&.{
            "-DGIT_WIN32",
            "-DGIT_WINHTTP",
        });
        artifact.addCSourceFiles(win32_srcs, flags.items);

        if (artifact.target.getAbi().isGnu()) {
            artifact.addCSourceFiles(posix_srcs, flags.items);
            artifact.addCSourceFiles(unix_srcs, flags.items);
        }
    } else {
        artifact.addCSourceFiles(posix_srcs, flags.items);
        artifact.addCSourceFiles(unix_srcs, flags.items);
    }

    if (artifact.target.isLinux())
        try flags.appendSlice(&.{
            "-DGIT_USE_NSEC=1",
            "-DGIT_USE_STAT_MTIM=1",
        });

    artifact.addCSourceFiles(zlib_srcs, &.{});
    artifact.addCSourceFiles(pcre_srcs, &.{
        "-DLINK_SIZE=2",
        "-DNEWLINE=10",
        "-DPOSIX_MALLOC_THRESHOLD=10",
        "-DMATCH_LIMIT_RECURSION=MATCH_LIMIT",
        "-DPARENS_NEST_LIMIT=250",
        "-DMATCH_LIMIT=10000000",
        "-DMAX_NAME_SIZE=32",
        "-DMAX_NAME_COUNT=10000",
    });

    artifact.addIncludeDir(root() ++
        std.fs.path.sep_str ++ "c" ++
        std.fs.path.sep_str ++ "include");
    artifact.addIncludeDir(root() ++
        std.fs.path.sep_str ++ "c" ++
        std.fs.path.sep_str ++ "src");
    artifact.addIncludeDir(root() ++
        std.fs.path.sep_str ++ "c" ++
        std.fs.path.sep_str ++ "deps" ++
        std.fs.path.sep_str ++ "zlib");
    artifact.addIncludeDir(root() ++
        std.fs.path.sep_str ++ "c" ++
        std.fs.path.sep_str ++ "deps" ++
        std.fs.path.sep_str ++ "pcre");
    artifact.addIncludeDir(root() ++
        std.fs.path.sep_str ++ "c" ++
        std.fs.path.sep_str ++ "deps" ++
        std.fs.path.sep_str ++ "http-parser");
    artifact.linkLibC();
}
