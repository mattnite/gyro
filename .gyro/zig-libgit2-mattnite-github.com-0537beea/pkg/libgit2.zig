const std = @import("std");

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

const root_path = root() ++ "/";
pub const include_dir = root_path ++ "libgit2/include";

pub const Library = struct {
    step: *std.build.LibExeObjStep,

    pub fn link(self: Library, other: *std.build.LibExeObjStep) void {
        other.addIncludePath(include_dir);
        other.linkLibrary(self.step);
    }
};

pub fn create(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !Library {
    const ret = b.addStaticLibrary("git2", null);
    ret.setTarget(target);
    ret.setBuildMode(mode);

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
        "-fno-sanitize=all",
    });

    if (64 == target.getCpuArch().ptrBitWidth())
        try flags.append("-DGIT_ARCH_64=1");

    ret.addCSourceFiles(srcs, flags.items);
    if (target.isWindows()) {
        try flags.appendSlice(&.{
            "-DGIT_WIN32",
            "-DGIT_WINHTTP",
        });
        ret.addCSourceFiles(win32_srcs, flags.items);

        if (target.getAbi().isGnu()) {
            ret.addCSourceFiles(posix_srcs, flags.items);
            ret.addCSourceFiles(unix_srcs, flags.items);
        }
    } else {
        ret.addCSourceFiles(posix_srcs, flags.items);
        ret.addCSourceFiles(unix_srcs, flags.items);
    }

    if (target.isLinux())
        try flags.appendSlice(&.{
            "-DGIT_USE_NSEC=1",
            "-DGIT_USE_STAT_MTIM=1",
        });

    ret.addCSourceFiles(pcre_srcs, &.{
        "-DLINK_SIZE=2",
        "-DNEWLINE=10",
        "-DPOSIX_MALLOC_THRESHOLD=10",
        "-DMATCH_LIMIT_RECURSION=MATCH_LIMIT",
        "-DPARENS_NEST_LIMIT=250",
        "-DMATCH_LIMIT=10000000",
        "-DMAX_NAME_SIZE=32",
        "-DMAX_NAME_COUNT=10000",
    });

    ret.addIncludePath(include_dir);
    ret.addIncludePath(root_path ++ "libgit2/src");
    ret.addIncludePath(root_path ++ "libgit2/deps/pcre");
    ret.addIncludePath(root_path ++ "libgit2/deps/http-parser");
    ret.linkLibC();

    return Library{ .step = ret };
}

const srcs = &.{
    root_path ++ "libgit2/deps/http-parser/http_parser.c",
    root_path ++ "libgit2/src/allocators/failalloc.c",
    root_path ++ "libgit2/src/allocators/stdalloc.c",
    root_path ++ "libgit2/src/streams/openssl.c",
    root_path ++ "libgit2/src/streams/registry.c",
    root_path ++ "libgit2/src/streams/socket.c",
    root_path ++ "libgit2/src/streams/tls.c",
    root_path ++ "mbedtls.c",
    root_path ++ "libgit2/src/transports/auth.c",
    root_path ++ "libgit2/src/transports/credential.c",
    root_path ++ "libgit2/src/transports/http.c",
    root_path ++ "libgit2/src/transports/httpclient.c",
    root_path ++ "libgit2/src/transports/smart_protocol.c",
    root_path ++ "libgit2/src/transports/ssh.c",
    root_path ++ "libgit2/src/transports/git.c",
    root_path ++ "libgit2/src/transports/smart.c",
    root_path ++ "libgit2/src/transports/smart_pkt.c",
    root_path ++ "libgit2/src/transports/local.c",
    root_path ++ "libgit2/src/xdiff/xdiffi.c",
    root_path ++ "libgit2/src/xdiff/xemit.c",
    root_path ++ "libgit2/src/xdiff/xhistogram.c",
    root_path ++ "libgit2/src/xdiff/xmerge.c",
    root_path ++ "libgit2/src/xdiff/xpatience.c",
    root_path ++ "libgit2/src/xdiff/xprepare.c",
    root_path ++ "libgit2/src/xdiff/xutils.c",
    root_path ++ "libgit2/src/hash/sha1/mbedtls.c",
    root_path ++ "libgit2/src/alloc.c",
    root_path ++ "libgit2/src/annotated_commit.c",
    root_path ++ "libgit2/src/apply.c",
    root_path ++ "libgit2/src/attr.c",
    root_path ++ "libgit2/src/attrcache.c",
    root_path ++ "libgit2/src/attr_file.c",
    root_path ++ "libgit2/src/blame.c",
    root_path ++ "libgit2/src/blame_git.c",
    root_path ++ "libgit2/src/blob.c",
    root_path ++ "libgit2/src/branch.c",
    root_path ++ "libgit2/src/buffer.c",
    root_path ++ "libgit2/src/cache.c",
    root_path ++ "libgit2/src/checkout.c",
    root_path ++ "libgit2/src/cherrypick.c",
    root_path ++ "libgit2/src/clone.c",
    root_path ++ "libgit2/src/commit.c",
    root_path ++ "libgit2/src/commit_graph.c",
    root_path ++ "libgit2/src/commit_list.c",
    root_path ++ "libgit2/src/config.c",
    root_path ++ "libgit2/src/config_cache.c",
    root_path ++ "libgit2/src/config_entries.c",
    root_path ++ "libgit2/src/config_file.c",
    root_path ++ "libgit2/src/config_mem.c",
    root_path ++ "libgit2/src/config_parse.c",
    root_path ++ "libgit2/src/config_snapshot.c",
    root_path ++ "libgit2/src/crlf.c",
    root_path ++ "libgit2/src/date.c",
    root_path ++ "libgit2/src/delta.c",
    root_path ++ "libgit2/src/describe.c",
    root_path ++ "libgit2/src/diff.c",
    root_path ++ "libgit2/src/diff_driver.c",
    root_path ++ "libgit2/src/diff_file.c",
    root_path ++ "libgit2/src/diff_generate.c",
    root_path ++ "libgit2/src/diff_parse.c",
    root_path ++ "libgit2/src/diff_print.c",
    root_path ++ "libgit2/src/diff_stats.c",
    root_path ++ "libgit2/src/diff_tform.c",
    root_path ++ "libgit2/src/diff_xdiff.c",
    root_path ++ "libgit2/src/errors.c",
    root_path ++ "libgit2/src/email.c",
    root_path ++ "libgit2/src/fetch.c",
    root_path ++ "libgit2/src/fetchhead.c",
    root_path ++ "libgit2/src/filebuf.c",
    root_path ++ "libgit2/src/filter.c",
    root_path ++ "libgit2/src/futils.c",
    root_path ++ "libgit2/src/graph.c",
    root_path ++ "libgit2/src/hash.c",
    root_path ++ "libgit2/src/hashsig.c",
    root_path ++ "libgit2/src/ident.c",
    root_path ++ "libgit2/src/idxmap.c",
    root_path ++ "libgit2/src/ignore.c",
    root_path ++ "libgit2/src/index.c",
    root_path ++ "libgit2/src/indexer.c",
    root_path ++ "libgit2/src/iterator.c",
    root_path ++ "libgit2/src/libgit2.c",
    root_path ++ "libgit2/src/mailmap.c",
    root_path ++ "libgit2/src/merge.c",
    root_path ++ "libgit2/src/merge_driver.c",
    root_path ++ "libgit2/src/merge_file.c",
    root_path ++ "libgit2/src/message.c",
    root_path ++ "libgit2/src/midx.c",
    root_path ++ "libgit2/src/mwindow.c",
    root_path ++ "libgit2/src/net.c",
    root_path ++ "libgit2/src/netops.c",
    root_path ++ "libgit2/src/notes.c",
    root_path ++ "libgit2/src/object_api.c",
    root_path ++ "libgit2/src/object.c",
    root_path ++ "libgit2/src/odb.c",
    root_path ++ "libgit2/src/odb_loose.c",
    root_path ++ "libgit2/src/odb_mempack.c",
    root_path ++ "libgit2/src/odb_pack.c",
    root_path ++ "libgit2/src/offmap.c",
    root_path ++ "libgit2/src/oidarray.c",
    root_path ++ "libgit2/src/oid.c",
    root_path ++ "libgit2/src/oidmap.c",
    root_path ++ "libgit2/src/pack.c",
    root_path ++ "libgit2/src/pack-objects.c",
    root_path ++ "libgit2/src/parse.c",
    root_path ++ "libgit2/src/patch.c",
    root_path ++ "libgit2/src/patch_generate.c",
    root_path ++ "libgit2/src/patch_parse.c",
    root_path ++ "libgit2/src/path.c",
    root_path ++ "libgit2/src/pathspec.c",
    root_path ++ "libgit2/src/pool.c",
    root_path ++ "libgit2/src/pqueue.c",
    root_path ++ "libgit2/src/proxy.c",
    root_path ++ "libgit2/src/push.c",
    root_path ++ "libgit2/src/reader.c",
    root_path ++ "libgit2/src/rebase.c",
    root_path ++ "libgit2/src/refdb.c",
    root_path ++ "libgit2/src/refdb_fs.c",
    root_path ++ "libgit2/src/reflog.c",
    root_path ++ "libgit2/src/refs.c",
    root_path ++ "libgit2/src/refspec.c",
    root_path ++ "libgit2/src/regexp.c",
    root_path ++ "libgit2/src/remote.c",
    root_path ++ "libgit2/src/repository.c",
    root_path ++ "libgit2/src/reset.c",
    root_path ++ "libgit2/src/revert.c",
    root_path ++ "libgit2/src/revparse.c",
    root_path ++ "libgit2/src/revwalk.c",
    root_path ++ "libgit2/src/runtime.c",
    root_path ++ "libgit2/src/signature.c",
    root_path ++ "libgit2/src/sortedcache.c",
    root_path ++ "libgit2/src/stash.c",
    root_path ++ "libgit2/src/status.c",
    root_path ++ "libgit2/src/strarray.c",
    root_path ++ "libgit2/src/strmap.c",
    root_path ++ "libgit2/src/submodule.c",
    root_path ++ "libgit2/src/sysdir.c",
    root_path ++ "libgit2/src/tag.c",
    root_path ++ "libgit2/src/thread.c",
    root_path ++ "libgit2/src/threadstate.c",
    root_path ++ "libgit2/src/trace.c",
    root_path ++ "libgit2/src/trailer.c",
    root_path ++ "libgit2/src/transaction.c",
    root_path ++ "libgit2/src/transport.c",
    root_path ++ "libgit2/src/tree.c",
    root_path ++ "libgit2/src/tree-cache.c",
    root_path ++ "libgit2/src/tsort.c",
    root_path ++ "libgit2/src/utf8.c",
    root_path ++ "libgit2/src/util.c",
    root_path ++ "libgit2/src/varint.c",
    root_path ++ "libgit2/src/vector.c",
    root_path ++ "libgit2/src/wildmatch.c",
    root_path ++ "libgit2/src/worktree.c",
    root_path ++ "libgit2/src/zstream.c",
};

const pcre_srcs = &.{
    root_path ++ "libgit2/deps/pcre/pcre_byte_order.c",
    root_path ++ "libgit2/deps/pcre/pcre_chartables.c",
    root_path ++ "libgit2/deps/pcre/pcre_compile.c",
    root_path ++ "libgit2/deps/pcre/pcre_config.c",
    root_path ++ "libgit2/deps/pcre/pcre_dfa_exec.c",
    root_path ++ "libgit2/deps/pcre/pcre_exec.c",
    root_path ++ "libgit2/deps/pcre/pcre_fullinfo.c",
    root_path ++ "libgit2/deps/pcre/pcre_get.c",
    root_path ++ "libgit2/deps/pcre/pcre_globals.c",
    root_path ++ "libgit2/deps/pcre/pcre_jit_compile.c",
    root_path ++ "libgit2/deps/pcre/pcre_maketables.c",
    root_path ++ "libgit2/deps/pcre/pcre_newline.c",
    root_path ++ "libgit2/deps/pcre/pcre_ord2utf8.c",
    root_path ++ "libgit2/deps/pcre/pcreposix.c",
    root_path ++ "libgit2/deps/pcre/pcre_printint.c",
    root_path ++ "libgit2/deps/pcre/pcre_refcount.c",
    root_path ++ "libgit2/deps/pcre/pcre_string_utils.c",
    root_path ++ "libgit2/deps/pcre/pcre_study.c",
    root_path ++ "libgit2/deps/pcre/pcre_tables.c",
    root_path ++ "libgit2/deps/pcre/pcre_ucd.c",
    root_path ++ "libgit2/deps/pcre/pcre_valid_utf8.c",
    root_path ++ "libgit2/deps/pcre/pcre_version.c",
    root_path ++ "libgit2/deps/pcre/pcre_xclass.c",
};

const posix_srcs = &.{
    root_path ++ "libgit2/src/posix.c",
};

const unix_srcs = &.{
    root_path ++ "libgit2/src/unix/map.c",
    root_path ++ "libgit2/src/unix/realpath.c",
};

const win32_srcs = &.{
    root_path ++ "libgit2/src/win32/dir.c",
    root_path ++ "libgit2/src/win32/error.c",
    root_path ++ "libgit2/src/win32/findfile.c",
    root_path ++ "libgit2/src/win32/map.c",
    root_path ++ "libgit2/src/win32/path_w32.c",
    root_path ++ "libgit2/src/win32/posix_w32.c",
    root_path ++ "libgit2/src/win32/precompiled.c",
    root_path ++ "libgit2/src/win32/thread.c",
    root_path ++ "libgit2/src/win32/utf-conv.c",
    root_path ++ "libgit2/src/win32/w32_buffer.c",
    root_path ++ "libgit2/src/win32/w32_leakcheck.c",
    root_path ++ "libgit2/src/win32/w32_util.c",
};
