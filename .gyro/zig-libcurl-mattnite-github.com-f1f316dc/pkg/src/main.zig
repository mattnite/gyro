const std = @import("std");
const testing = std.testing;

pub const c = @cImport({
    @cInclude("curl/curl.h");
});

pub fn globalInit() Error!void {
    return tryCurl(c.curl_global_init(c.CURL_GLOBAL_ALL));
}

pub fn globalCleanup() void {
    c.curl_global_cleanup();
}

pub const XferInfoFn = c.curl_xferinfo_callback;
pub const WriteFn = c.curl_write_callback;
pub const ReadFn = c.curl_read_callback;
pub const Offset = c.curl_off_t;

/// if you set this as a write function, you must set write data to a fifo of the same type
pub fn writeToFifo(comptime FifoType: type) WriteFn {
    return struct {
        fn writeFn(ptr: ?[*]u8, size: usize, nmemb: usize, data: ?*anyopaque) callconv(.C) usize {
            _ = size;
            var slice = (ptr orelse return 0)[0..nmemb];
            const fifo = @ptrCast(
                *FifoType,
                @alignCast(
                    @alignOf(*FifoType),
                    data orelse return 0,
                ),
            );

            fifo.writer().writeAll(slice) catch return 0;
            return nmemb;
        }
    }.writeFn;
}

/// if you set this as a read function, you must set read data to an FBS of the same type
pub fn readFromFbs(comptime FbsType: type) ReadFn {
    const BufferType = switch (FbsType) {
        std.io.FixedBufferStream([]u8) => []u8,
        std.io.FixedBufferStream([]const u8) => []const u8,
        else => @compileError("std.io.FixedBufferStream can only have []u8 or []const u8 buffer type"),
    };
    return struct {
        fn readFn(buffer: ?[*]u8, size: usize, nitems: usize, data: ?*anyopaque) callconv(.C) usize {
            const to = (buffer orelse return c.CURL_READFUNC_ABORT)[0 .. size * nitems];
            var fbs = @ptrCast(
                *std.io.FixedBufferStream(BufferType),
                @alignCast(
                    @alignOf(*std.io.FixedBufferStream(BufferType)),
                    data orelse return c.CURL_READFUNC_ABORT,
                ),
            );

            return fbs.read(to) catch |err| blk: {
                std.log.err("get fbs read error: {s}", .{@errorName(err)});
                break :blk c.CURL_READFUNC_ABORT;
            };
        }
    }.readFn;
}

pub const Easy = opaque {
    pub fn init() Error!*Easy {
        return @ptrCast(?*Easy, c.curl_easy_init()) orelse error.FailedInit;
    }

    pub fn cleanup(self: *Easy) void {
        c.curl_easy_cleanup(self);
    }

    pub fn setUrl(self: *Easy, url: [:0]const u8) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_URL, url.ptr));
    }

    pub fn setFollowLocation(self: *Easy, val: bool) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_FOLLOWLOCATION, @as(c_ulong, if (val) 1 else 0)));
    }

    pub fn setVerbose(self: *Easy, val: bool) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_VERBOSE, @as(c_ulong, if (val) 1 else 0)));
    }

    pub fn setSslVerifyPeer(self: *Easy, val: bool) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_SSL_VERIFYPEER, @as(c_ulong, if (val) 1 else 0)));
    }

    pub fn setAcceptEncodingGzip(self: *Easy) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_ACCEPT_ENCODING, "gzip"));
    }

    pub fn setReadFn(self: *Easy, read: ReadFn) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_READFUNCTION, read));
    }

    pub fn setReadData(self: *Easy, data: *anyopaque) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_READDATA, data));
    }

    pub fn setWriteFn(self: *Easy, write: WriteFn) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_WRITEFUNCTION, write));
    }

    pub fn setWriteData(self: *Easy, data: *anyopaque) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_WRITEDATA, data));
    }

    pub fn setNoProgress(self: *Easy, val: bool) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_NOPROGRESS, @as(c_ulong, if (val) 1 else 0)));
    }

    pub fn setXferInfoFn(self: *Easy, xfer: XferInfoFn) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_XFERINFOFUNCTION, xfer));
    }

    pub fn setXferInfoData(self: *Easy, data: *anyopaque) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_XFERINFODATA, data));
    }

    pub fn setErrorBuffer(self: *Easy, data: *[c.CURL_ERROR_SIZE]u8) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_XFERINFODATA, data));
    }

    pub fn setHeaders(self: *Easy, headers: HeaderList) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_HTTPHEADER, headers.inner));
    }

    pub fn setPost(self: *Easy) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_POST, @as(c_ulong, 1)));
    }

    pub fn setPostFields(self: *Easy, data: *anyopaque) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_POSTFIELDS, @ptrToInt(data)));
    }

    pub fn setPostFieldSize(self: *Easy, size: usize) Error!void {
        return tryCurl(c.curl_easy_setopt(self, c.CURLOPT_POSTFIELDSIZE, @intCast(c_ulong, size)));
    }

    pub fn perform(self: *Easy) Error!void {
        return tryCurl(c.curl_easy_perform(self));
    }

    pub fn getResponseCode(self: *Easy) Error!isize {
        var code: isize = 0;
        try tryCurl(c.curl_easy_getinfo(self, c.CURLINFO_RESPONSE_CODE, &code));
        return code;
    }
};

fn emptyWrite(ptr: ?[*]u8, size: usize, nmemb: usize, data: ?*anyopaque) callconv(.C) usize {
    _ = ptr;
    _ = data;
    _ = size;

    return nmemb;
}

test "https get" {
    const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });

    try globalInit();
    defer globalCleanup();

    var fifo = Fifo.init(std.testing.allocator);
    defer fifo.deinit();

    var easy = try Easy.init();
    defer easy.cleanup();

    try easy.setUrl("https://httpbin.org/get");
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setVerbose(true);
    try easy.perform();
    const code = try easy.getResponseCode();

    try std.testing.expectEqual(@as(isize, 200), code);
}

test "https get gzip encoded" {
    const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });

    try globalInit();
    defer globalCleanup();

    var fifo = Fifo.init(std.testing.allocator);
    defer fifo.deinit();

    var easy = try Easy.init();
    defer easy.cleanup();

    try easy.setUrl("http://httpbin.org/gzip");
    try easy.setSslVerifyPeer(false);
    try easy.setAcceptEncodingGzip();
    try easy.setWriteFn(writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setVerbose(true);
    try easy.perform();
    const code = try easy.getResponseCode();

    try std.testing.expectEqual(@as(isize, 200), code);
}

test "https post" {
    try globalInit();
    defer globalCleanup();

    var easy = try Easy.init();
    defer easy.cleanup();

    const payload = "this is a payload";
    var fbs = std.io.fixedBufferStream(payload);
    fbs.pos = payload.len;

    try easy.setUrl("https://httpbin.org/post");
    try easy.setPost();
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(emptyWrite);
    try easy.setReadFn(readFromFbs(@TypeOf(fbs)));
    try easy.setReadData(&fbs);
    try easy.setVerbose(true);
    try easy.perform();
    const code = try easy.getResponseCode();

    try std.testing.expectEqual(@as(isize, 200), code);
}

pub const Url = opaque {
    pub fn init() UrlError!*Url {
        return @ptrCast(?*Url, c.curl_url()) orelse error.FailedInit;
    }

    pub fn cleanup(self: *Url) void {
        c.curl_url_cleanup(@ptrCast(*c.CURLU, self));
    }

    pub fn set(self: *Url, url: [:0]const u8) UrlError!void {
        return tryCurlUrl(c.curl_url_set(@ptrCast(*c.CURLU, self), c.CURLUPART_URL, url.ptr, 0));
    }

    pub fn getHost(self: *Url) UrlError![*:0]u8 {
        var host: ?[*:0]u8 = undefined;
        try tryCurlUrl(c.curl_url_get(@ptrCast(*c.CURLU, self), c.CURLUPART_HOST, &host, 0));
        return host.?;
    }

    pub fn getPath(self: *Url) UrlError![*:0]u8 {
        var path: ?[*:0]u8 = undefined;
        try tryCurlUrl(c.curl_url_get(@ptrCast(*c.CURLU, self), c.CURLUPART_PATH, &path, 0));
        return path.?;
    }

    pub fn getScheme(self: *Url) UrlError![*:0]u8 {
        var scheme: ?[*:0]u8 = undefined;
        try tryCurlUrl(c.curl_url_get(@ptrCast(*c.CURLU, self), c.CURLUPART_SCHEME, &scheme, 0));
        return scheme.?;
    }

    pub fn getPort(self: *Url) UrlError![*:0]u8 {
        var port: ?[*:0]u8 = undefined;
        try tryCurlUrl(c.curl_url_get(@ptrCast(*c.CURLU, self), c.CURLUPART_PORT, &port, 0));
        return port.?;
    }

    pub fn getQuery(self: *Url) UrlError![*:0]u8 {
        var query: ?[*:0]u8 = undefined;
        try tryCurlUrl(c.curl_url_get(@ptrCast(*c.CURLU, self), c.CURLUPART_QUERY, &query, 0));
        return query.?;
    }

    fn tryCurlUrl(code: c.CURLUcode) UrlError!void {
        if (code != c.CURLUE_OK)
            return errorFromCurlUrl(code);
    }
};

test "parse url" {
    const url = try Url.init();
    defer url.cleanup();

    try url.set("https://arst.com:80/blarg/foo.git?what=yes&please=no");

    const scheme = try url.getScheme();
    try std.testing.expectEqualStrings("https", std.mem.span(scheme));

    const host = try url.getHost();
    try std.testing.expectEqualStrings("arst.com", std.mem.span(host));

    const port = try url.getPort();
    try std.testing.expectEqualStrings("80", std.mem.span(port));

    const path = try url.getPath();
    try std.testing.expectEqualStrings("/blarg/foo.git", std.mem.span(path));

    const query = try url.getQuery();
    try std.testing.expectEqualStrings("what=yes&please=no", std.mem.span(query));
}

pub const HeaderList = struct {
    inner: ?*c.curl_slist,

    pub fn init() HeaderList {
        return HeaderList{
            .inner = null,
        };
    }

    pub fn freeAll(self: *HeaderList) void {
        c.curl_slist_free_all(self.inner);
    }

    pub fn append(self: *HeaderList, entry: [:0]const u8) !void {
        if (c.curl_slist_append(self.inner, entry.ptr)) |list| {
            self.inner = list;
        } else return error.CurlHeadersAppend;
    }
};

test "headers" {
    try globalInit();
    defer globalCleanup();

    var headers = HeaderList.init();
    defer headers.freeAll();

    // removes a header curl would put in for us
    try headers.append("Accept:");

    // a custom header
    try headers.append("MyCustomHeader: bruh");

    // a header with no value, note the semicolon
    try headers.append("ThisHasNoValue;");

    var easy = try Easy.init();
    defer easy.cleanup();

    try easy.setUrl("https://httpbin.org/get");
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(emptyWrite);
    try easy.setVerbose(true);
    try easy.setHeaders(headers);
    try easy.perform();
    const code = try easy.getResponseCode();

    try std.testing.expectEqual(@as(isize, 200), code);
}

pub const UrlError = error{
    FailedInit,
    BadHandle,
    BadPartpointer,
    MalformedInput,
    BadPortNumber,
    UnsupportedScheme,
    UrlDecode,
    OutOfMemory,
    UserNotAllowed,
    UnknownPart,
    NoScheme,
    NoUser,
    NoPassword,
    NoOptions,
    NoHost,
    NoPort,
    NoQuery,
    NoFragment,
    UnknownErrorCode,
};

pub const Error = error{
    UnsupportedProtocol,
    FailedInit,
    UrlMalformat,
    NotBuiltIn,
    CouldntResolveProxy,
    CouldntResolveHost,
    CounldntConnect,
    WeirdServerReply,
    RemoteAccessDenied,
    FtpAcceptFailed,
    FtpWeirdPassReply,
    FtpAcceptTimeout,
    FtpWeirdPasvReply,
    FtpWeird227Format,
    FtpCantGetHost,
    Http2,
    FtpCouldntSetType,
    PartialFile,
    FtpCouldntRetrFile,
    Obsolete20,
    QuoteError,
    HttpReturnedError,
    WriteError,
    Obsolete24,
    UploadFailed,
    ReadError,
    OutOfMemory,
    OperationTimeout,
    Obsolete29,
    FtpPortFailed,
    FtpCouldntUseRest,
    Obsolete32,
    RangeError,
    HttpPostError,
    SslConnectError,
    BadDownloadResume,
    FileCouldntReadFile,
    LdapCannotBind,
    LdapSearchFailed,
    Obsolete40,
    FunctionNotFound,
    AbortByCallback,
    BadFunctionArgument,
    Obsolete44,
    InterfaceFailed,
    Obsolete46,
    TooManyRedirects,
    UnknownOption,
    SetoptOptionSyntax,
    Obsolete50,
    Obsolete51,
    GotNothing,
    SslEngineNotfound,
    SslEngineSetfailed,
    SendError,
    RecvError,
    Obsolete57,
    SslCertproblem,
    SslCipher,
    PeerFailedVerification,
    BadContentEncoding,
    LdapInvalidUrl,
    FilesizeExceeded,
    UseSslFailed,
    SendFailRewind,
    SslEngineInitfailed,
    LoginDenied,
    TftpNotfound,
    TftpPerm,
    RemoteDiskFull,
    TftpIllegal,
    Tftp_Unknownid,
    RemoteFileExists,
    TftpNosuchuser,
    ConvFailed,
    ConvReqd,
    SslCacertBadfile,
    RemoteFileNotFound,
    Ssh,
    SslShutdownFailed,
    Again,
    SslCrlBadfile,
    SslIssuerError,
    FtpPretFailed,
    RtspCseqError,
    RtspSessionError,
    FtpBadFileList,
    ChunkFailed,
    NoConnectionAvailable,
    SslPinnedpubkeynotmatch,
    SslInvalidcertstatus,
    Http2Stream,
    RecursiveApiCall,
    AuthError,
    Http3,
    QuicConnectError,
    Proxy,
    SslClientCert,
    UnknownErrorCode,
};

fn tryCurl(code: c.CURLcode) Error!void {
    if (code != c.CURLE_OK)
        return errorFromCurl(code);
}

fn errorFromCurl(code: c.CURLcode) Error {
    return switch (code) {
        c.CURLE_UNSUPPORTED_PROTOCOL => error.UnsupportedProtocol,
        c.CURLE_FAILED_INIT => error.FailedInit,
        c.CURLE_URL_MALFORMAT => error.UrlMalformat,
        c.CURLE_NOT_BUILT_IN => error.NotBuiltIn,
        c.CURLE_COULDNT_RESOLVE_PROXY => error.CouldntResolveProxy,
        c.CURLE_COULDNT_RESOLVE_HOST => error.CouldntResolveHost,
        c.CURLE_COULDNT_CONNECT => error.CounldntConnect,
        c.CURLE_WEIRD_SERVER_REPLY => error.WeirdServerReply,
        c.CURLE_REMOTE_ACCESS_DENIED => error.RemoteAccessDenied,
        c.CURLE_FTP_ACCEPT_FAILED => error.FtpAcceptFailed,
        c.CURLE_FTP_WEIRD_PASS_REPLY => error.FtpWeirdPassReply,
        c.CURLE_FTP_ACCEPT_TIMEOUT => error.FtpAcceptTimeout,
        c.CURLE_FTP_WEIRD_PASV_REPLY => error.FtpWeirdPasvReply,
        c.CURLE_FTP_WEIRD_227_FORMAT => error.FtpWeird227Format,
        c.CURLE_FTP_CANT_GET_HOST => error.FtpCantGetHost,
        c.CURLE_HTTP2 => error.Http2,
        c.CURLE_FTP_COULDNT_SET_TYPE => error.FtpCouldntSetType,
        c.CURLE_PARTIAL_FILE => error.PartialFile,
        c.CURLE_FTP_COULDNT_RETR_FILE => error.FtpCouldntRetrFile,
        c.CURLE_OBSOLETE20 => error.Obsolete20,
        c.CURLE_QUOTE_ERROR => error.QuoteError,
        c.CURLE_HTTP_RETURNED_ERROR => error.HttpReturnedError,
        c.CURLE_WRITE_ERROR => error.WriteError,
        c.CURLE_OBSOLETE24 => error.Obsolete24,
        c.CURLE_UPLOAD_FAILED => error.UploadFailed,
        c.CURLE_READ_ERROR => error.ReadError,
        c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLE_OPERATION_TIMEDOUT => error.OperationTimeout,
        c.CURLE_OBSOLETE29 => error.Obsolete29,
        c.CURLE_FTP_PORT_FAILED => error.FtpPortFailed,
        c.CURLE_FTP_COULDNT_USE_REST => error.FtpCouldntUseRest,
        c.CURLE_OBSOLETE32 => error.Obsolete32,
        c.CURLE_RANGE_ERROR => error.RangeError,
        c.CURLE_HTTP_POST_ERROR => error.HttpPostError,
        c.CURLE_SSL_CONNECT_ERROR => error.SslConnectError,
        c.CURLE_BAD_DOWNLOAD_RESUME => error.BadDownloadResume,
        c.CURLE_FILE_COULDNT_READ_FILE => error.FileCouldntReadFile,
        c.CURLE_LDAP_CANNOT_BIND => error.LdapCannotBind,
        c.CURLE_LDAP_SEARCH_FAILED => error.LdapSearchFailed,
        c.CURLE_OBSOLETE40 => error.Obsolete40,
        c.CURLE_FUNCTION_NOT_FOUND => error.FunctionNotFound,
        c.CURLE_ABORTED_BY_CALLBACK => error.AbortByCallback,
        c.CURLE_BAD_FUNCTION_ARGUMENT => error.BadFunctionArgument,
        c.CURLE_OBSOLETE44 => error.Obsolete44,
        c.CURLE_INTERFACE_FAILED => error.InterfaceFailed,
        c.CURLE_OBSOLETE46 => error.Obsolete46,
        c.CURLE_TOO_MANY_REDIRECTS => error.TooManyRedirects,
        c.CURLE_UNKNOWN_OPTION => error.UnknownOption,
        c.CURLE_SETOPT_OPTION_SYNTAX => error.SetoptOptionSyntax,
        c.CURLE_OBSOLETE50 => error.Obsolete50,
        c.CURLE_OBSOLETE51 => error.Obsolete51,
        c.CURLE_GOT_NOTHING => error.GotNothing,
        c.CURLE_SSL_ENGINE_NOTFOUND => error.SslEngineNotfound,
        c.CURLE_SSL_ENGINE_SETFAILED => error.SslEngineSetfailed,
        c.CURLE_SEND_ERROR => error.SendError,
        c.CURLE_RECV_ERROR => error.RecvError,
        c.CURLE_OBSOLETE57 => error.Obsolete57,
        c.CURLE_SSL_CERTPROBLEM => error.SslCertproblem,
        c.CURLE_SSL_CIPHER => error.SslCipher,
        c.CURLE_PEER_FAILED_VERIFICATION => error.PeerFailedVerification,
        c.CURLE_BAD_CONTENT_ENCODING => error.BadContentEncoding,
        c.CURLE_LDAP_INVALID_URL => error.LdapInvalidUrl,
        c.CURLE_FILESIZE_EXCEEDED => error.FilesizeExceeded,
        c.CURLE_USE_SSL_FAILED => error.UseSslFailed,
        c.CURLE_SEND_FAIL_REWIND => error.SendFailRewind,
        c.CURLE_SSL_ENGINE_INITFAILED => error.SslEngineInitfailed,
        c.CURLE_LOGIN_DENIED => error.LoginDenied,
        c.CURLE_TFTP_NOTFOUND => error.TftpNotfound,
        c.CURLE_TFTP_PERM => error.TftpPerm,
        c.CURLE_REMOTE_DISK_FULL => error.RemoteDiskFull,
        c.CURLE_TFTP_ILLEGAL => error.TftpIllegal,
        c.CURLE_TFTP_UNKNOWNID => error.Tftp_Unknownid,
        c.CURLE_REMOTE_FILE_EXISTS => error.RemoteFileExists,
        c.CURLE_TFTP_NOSUCHUSER => error.TftpNosuchuser,
        c.CURLE_CONV_FAILED => error.ConvFailed,
        c.CURLE_CONV_REQD => error.ConvReqd,
        c.CURLE_SSL_CACERT_BADFILE => error.SslCacertBadfile,
        c.CURLE_REMOTE_FILE_NOT_FOUND => error.RemoteFileNotFound,
        c.CURLE_SSH => error.Ssh,
        c.CURLE_SSL_SHUTDOWN_FAILED => error.SslShutdownFailed,
        c.CURLE_AGAIN => error.Again,
        c.CURLE_SSL_CRL_BADFILE => error.SslCrlBadfile,
        c.CURLE_SSL_ISSUER_ERROR => error.SslIssuerError,
        c.CURLE_FTP_PRET_FAILED => error.FtpPretFailed,
        c.CURLE_RTSP_CSEQ_ERROR => error.RtspCseqError,
        c.CURLE_RTSP_SESSION_ERROR => error.RtspSessionError,
        c.CURLE_FTP_BAD_FILE_LIST => error.FtpBadFileList,
        c.CURLE_CHUNK_FAILED => error.ChunkFailed,
        c.CURLE_NO_CONNECTION_AVAILABLE => error.NoConnectionAvailable,
        c.CURLE_SSL_PINNEDPUBKEYNOTMATCH => error.SslPinnedpubkeynotmatch,
        c.CURLE_SSL_INVALIDCERTSTATUS => error.SslInvalidcertstatus,
        c.CURLE_HTTP2_STREAM => error.Http2Stream,
        c.CURLE_RECURSIVE_API_CALL => error.RecursiveApiCall,
        c.CURLE_AUTH_ERROR => error.AuthError,
        c.CURLE_HTTP3 => error.Http3,
        c.CURLE_QUIC_CONNECT_ERROR => error.QuicConnectError,
        c.CURLE_PROXY => error.Proxy,
        c.CURLE_SSL_CLIENTCERT => error.SslClientCert,

        else => blk: {
            std.debug.assert(false);
            break :blk error.UnknownErrorCode;
        },
    };
}

fn errorFromCurlUrl(code: c.CURLUcode) UrlError {
    return switch (code) {
        c.CURLUE_BAD_HANDLE => error.BadHandle,
        c.CURLUE_BAD_PARTPOINTER => error.BadPartpointer,
        c.CURLUE_MALFORMED_INPUT => error.MalformedInput,
        c.CURLUE_BAD_PORT_NUMBER => error.BadPortNumber,
        c.CURLUE_UNSUPPORTED_SCHEME => error.UnsupportedScheme,
        c.CURLUE_URLDECODE => error.UrlDecode,
        c.CURLUE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLUE_USER_NOT_ALLOWED => error.UserNotAllowed,
        c.CURLUE_UNKNOWN_PART => error.UnknownPart,
        c.CURLUE_NO_SCHEME => error.NoScheme,
        c.CURLUE_NO_USER => error.NoUser,
        c.CURLUE_NO_PASSWORD => error.NoPassword,
        c.CURLUE_NO_OPTIONS => error.NoOptions,
        c.CURLUE_NO_HOST => error.NoHost,
        c.CURLUE_NO_PORT => error.NoPort,
        c.CURLUE_NO_QUERY => error.NoQuery,
        c.CURLUE_NO_FRAGMENT => error.NoFragment,
        else => blk: {
            std.debug.assert(false);
            break :blk error.UnknownErrorCode;
        },
    };
}
