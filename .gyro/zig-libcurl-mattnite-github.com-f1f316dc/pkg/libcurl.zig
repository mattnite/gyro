const std = @import("std");

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root() ++ "/";

pub const include_dir = root_path ++ "curl/include";
const package_path = root_path ++ "src/main.zig";
const lib_dir = root_path ++ "curl/lib";

pub const Define = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Options = struct {
    import_name: ?[]const u8 = null,
};

pub const Library = struct {
    exported_defines: []Define,
    step: *std.build.LibExeObjStep,

    pub fn link(self: Library, other: *std.build.LibExeObjStep, opts: Options) void {
        for (self.exported_defines) |def|
            other.defineCMacro(def.key, def.value);

        other.addIncludeDir(include_dir);
        other.linkLibrary(self.step);

        if (opts.import_name) |import_name|
            other.addPackagePath(import_name, package_path);
    }
};

pub fn create(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !Library {
    const ret = b.addStaticLibrary("curl", null);
    ret.setTarget(target);
    ret.setBuildMode(mode);
    ret.addCSourceFiles(srcs, &.{});
    ret.addIncludeDir(include_dir);
    ret.addIncludeDir(lib_dir);
    ret.linkLibC();

    var exported_defines = std.ArrayList(Define).init(b.allocator);
    defer exported_defines.deinit();

    ret.defineCMacro("BUILDING_LIBCURL", null);

    // when not building a shared library
    ret.defineCMacro("CURL_STATICLIB", "1");
    try exported_defines.append(.{ .key = "CURL_STATICLIB", .value = "1" });

    // disables LDAP
    ret.defineCMacro("CURL_DISABLE_LDAP", "1");

    // disables LDAPS
    ret.defineCMacro("CURL_DISABLE_LDAPS", "1");

    // if mbedTLS is enabled
    ret.defineCMacro("USE_MBEDTLS", "1");

    // disables alt-svc
    // #undef CURL_DISABLE_ALTSVC

    // disables cookies support
    // #undef CURL_DISABLE_COOKIES

    // disables cryptographic authentication
    // #undef CURL_DISABLE_CRYPTO_AUTH

    // disables DICT
    ret.defineCMacro("CURL_DISABLE_DICT", "1");

    // disables DNS-over-HTTPS
    // #undef CURL_DISABLE_DOH

    // disables FILE
    ret.defineCMacro("CURL_DISABLE_FILE", "1");

    // disables FTP
    ret.defineCMacro("CURL_DISABLE_FTP", "1");

    // disables GOPHER
    ret.defineCMacro("CURL_DISABLE_GOPHER", "1");

    // disables HSTS support
    // #undef CURL_DISABLE_HSTS

    // disables HTTP
    // #undef CURL_DISABLE_HTTP

    // disables IMAP
    ret.defineCMacro("CURL_DISABLE_IMAP", "1");

    // disables --libcurl option from the curl tool
    // #undef CURL_DISABLE_LIBCURL_OPTION

    // disables MIME support
    // #undef CURL_DISABLE_MIME

    // disables MQTT
    ret.defineCMacro("CURL_DISABLE_MQTT", "1");

    // disables netrc parser
    // #undef CURL_DISABLE_NETRC

    // disables NTLM support
    // #undef CURL_DISABLE_NTLM

    // disables date parsing
    // #undef CURL_DISABLE_PARSEDATE

    // disables POP3
    ret.defineCMacro("CURL_DISABLE_POP3", "1");

    // disables built-in progress meter
    // #undef CURL_DISABLE_PROGRESS_METER

    // disables proxies
    // #undef CURL_DISABLE_PROXY

    // disables RTSP
    ret.defineCMacro("CURL_DISABLE_RTSP", "1");

    // disables SMB
    ret.defineCMacro("CURL_DISABLE_SMB", "1");

    // disables SMTP
    ret.defineCMacro("CURL_DISABLE_SMTP", "1");

    // disables use of socketpair for curl_multi_poll
    // #undef CURL_DISABLE_SOCKETPAIR

    // disables TELNET
    ret.defineCMacro("CURL_DISABLE_TELNET", "1");

    // disables TFTP
    ret.defineCMacro("CURL_DISABLE_TFTP", "1");

    // disables verbose strings
    // #undef CURL_DISABLE_VERBOSE_STRINGS

    // Define to 1 if you have the `ssh2' library (-lssh2).
    ret.defineCMacro("HAVE_LIBSSH2", "1");

    // Define to 1 if you have the <libssh2.h> header file.
    ret.defineCMacro("HAVE_LIBSSH2_H", "1");

    // if zlib is available
    ret.defineCMacro("HAVE_LIBZ", "1");

    // if you have the zlib.h header file
    ret.defineCMacro("HAVE_ZLIB_H", "1");

    if (target.isWindows()) {
        // Define if you want to enable WIN32 threaded DNS lookup
        //ret.defineCMacro("USE_THREADS_WIN32", "1");

        return Library{ .step = ret, .exported_defines = exported_defines.toOwnedSlice() };
    }

    //ret.defineCMacro("libcurl_EXPORTS", null);

    //ret.defineCMacro("STDC_HEADERS", null);

    // when building libcurl itself
    // #undef BUILDING_LIBCURL

    // Location of default ca bundle
    // ret.defineCMacro("CURL_CA_BUNDLE", "\"/etc/ssl/certs/ca-certificates.crt\"");

    // define "1" to use built-in ca store of TLS backend
    // #undef CURL_CA_FALLBACK

    // Location of default ca path
    // ret.defineCMacro("CURL_CA_PATH", "\"/etc/ssl/certs\"");

    // to make a symbol visible
    ret.defineCMacro("CURL_EXTERN_SYMBOL", "__attribute__ ((__visibility__ (\"default\"))");
    // Ensure using CURL_EXTERN_SYMBOL is possible
    //#ifndef CURL_EXTERN_SYMBOL
    //ret.defineCMacro("CURL_EXTERN_SYMBOL
    //#endif

    // Allow SMB to work on Windows
    // #undef USE_WIN32_CRYPTO

    // Use Windows LDAP implementation
    // #undef USE_WIN32_LDAP

    // your Entropy Gathering Daemon socket pathname
    // #undef EGD_SOCKET

    // Define if you want to enable IPv6 support
    if (!target.isDarwin())
        ret.defineCMacro("ENABLE_IPV6", "1");

    // Define to 1 if you have the alarm function.
    ret.defineCMacro("HAVE_ALARM", "1");

    // Define to 1 if you have the <alloca.h> header file.
    ret.defineCMacro("HAVE_ALLOCA_H", "1");

    // Define to 1 if you have the <arpa/inet.h> header file.
    ret.defineCMacro("HAVE_ARPA_INET_H", "1");

    // Define to 1 if you have the <arpa/tftp.h> header file.
    ret.defineCMacro("HAVE_ARPA_TFTP_H", "1");

    // Define to 1 if you have the <assert.h> header file.
    ret.defineCMacro("HAVE_ASSERT_H", "1");

    // Define to 1 if you have the `basename' function.
    ret.defineCMacro("HAVE_BASENAME", "1");

    // Define to 1 if bool is an available type.
    ret.defineCMacro("HAVE_BOOL_T", "1");

    // Define to 1 if you have the __builtin_available function.
    ret.defineCMacro("HAVE_BUILTIN_AVAILABLE", "1");

    // Define to 1 if you have the clock_gettime function and monotonic timer.
    ret.defineCMacro("HAVE_CLOCK_GETTIME_MONOTONIC", "1");

    // Define to 1 if you have the `closesocket' function.
    // #undef HAVE_CLOSESOCKET

    // Define to 1 if you have the `CRYPTO_cleanup_all_ex_data' function.
    // #undef HAVE_CRYPTO_CLEANUP_ALL_EX_DATA

    // Define to 1 if you have the <dlfcn.h> header file.
    ret.defineCMacro("HAVE_DLFCN_H", "1");

    // Define to 1 if you have the <errno.h> header file.
    ret.defineCMacro("HAVE_ERRNO_H", "1");

    // Define to 1 if you have the fcntl function.
    ret.defineCMacro("HAVE_FCNTL", "1");

    // Define to 1 if you have the <fcntl.h> header file.
    ret.defineCMacro("HAVE_FCNTL_H", "1");

    // Define to 1 if you have a working fcntl O_NONBLOCK function.
    ret.defineCMacro("HAVE_FCNTL_O_NONBLOCK", "1");

    // Define to 1 if you have the freeaddrinfo function.
    ret.defineCMacro("HAVE_FREEADDRINFO", "1");

    // Define to 1 if you have the ftruncate function.
    ret.defineCMacro("HAVE_FTRUNCATE", "1");

    // Define to 1 if you have a working getaddrinfo function.
    ret.defineCMacro("HAVE_GETADDRINFO", "1");

    // Define to 1 if you have the `geteuid' function.
    ret.defineCMacro("HAVE_GETEUID", "1");

    // Define to 1 if you have the `getppid' function.
    ret.defineCMacro("HAVE_GETPPID", "1");

    // Define to 1 if you have the gethostbyname function.
    ret.defineCMacro("HAVE_GETHOSTBYNAME", "1");

    // Define to 1 if you have the gethostbyname_r function.
    if (!target.isDarwin())
        ret.defineCMacro("HAVE_GETHOSTBYNAME_R", "1");

    // gethostbyname_r() takes 3 args
    // #undef HAVE_GETHOSTBYNAME_R_3

    // gethostbyname_r() takes 5 args
    // #undef HAVE_GETHOSTBYNAME_R_5

    // gethostbyname_r() takes 6 args
    ret.defineCMacro("HAVE_GETHOSTBYNAME_R_6", "1");

    // Define to 1 if you have the gethostname function.
    ret.defineCMacro("HAVE_GETHOSTNAME", "1");

    // Define to 1 if you have a working getifaddrs function.
    // #undef HAVE_GETIFADDRS

    // Define to 1 if you have the `getpass_r' function.
    // #undef HAVE_GETPASS_R

    // Define to 1 if you have the `getppid' function.
    ret.defineCMacro("HAVE_GETPPID", "1");

    // Define to 1 if you have the `getprotobyname' function.
    ret.defineCMacro("HAVE_GETPROTOBYNAME", "1");

    // Define to 1 if you have the `getpeername' function.
    ret.defineCMacro("HAVE_GETPEERNAME", "1");

    // Define to 1 if you have the `getsockname' function.
    ret.defineCMacro("HAVE_GETSOCKNAME", "1");

    // Define to 1 if you have the `if_nametoindex' function.
    ret.defineCMacro("HAVE_IF_NAMETOINDEX", "1");

    // Define to 1 if you have the `getpwuid' function.
    ret.defineCMacro("HAVE_GETPWUID", "1");

    // Define to 1 if you have the `getpwuid_r' function.
    ret.defineCMacro("HAVE_GETPWUID_R", "1");

    // Define to 1 if you have the `getrlimit' function.
    ret.defineCMacro("HAVE_GETRLIMIT", "1");

    // Define to 1 if you have the `gettimeofday' function.
    ret.defineCMacro("HAVE_GETTIMEOFDAY", "1");

    // Define to 1 if you have a working glibc-style strerror_r function.
    // #undef HAVE_GLIBC_STRERROR_R

    // Define to 1 if you have a working gmtime_r function.
    ret.defineCMacro("HAVE_GMTIME_R", "1");

    // if you have the gssapi libraries
    // #undef HAVE_GSSAPI

    // Define to 1 if you have the <gssapi/gssapi_generic.h> header file.
    // #undef HAVE_GSSAPI_GSSAPI_GENERIC_H

    // Define to 1 if you have the <gssapi/gssapi.h> header file.
    // #undef HAVE_GSSAPI_GSSAPI_H

    // Define to 1 if you have the <gssapi/gssapi_krb5.h> header file.
    // #undef HAVE_GSSAPI_GSSAPI_KRB5_H

    // if you have the GNU gssapi libraries
    // #undef HAVE_GSSGNU

    // if you have the Heimdal gssapi libraries
    // #undef HAVE_GSSHEIMDAL

    // if you have the MIT gssapi libraries
    // #undef HAVE_GSSMIT

    // Define to 1 if you have the `idna_strerror' function.
    // #undef HAVE_IDNA_STRERROR

    // Define to 1 if you have the `idn_free' function.
    // #undef HAVE_IDN_FREE

    // Define to 1 if you have the <idn-free.h> header file.
    // #undef HAVE_IDN_FREE_H

    // Define to 1 if you have the <ifaddrs.h> header file.
    ret.defineCMacro("HAVE_IFADDRS_H", "1");

    // Define to 1 if you have the `inet_addr' function.
    ret.defineCMacro("HAVE_INET_ADDR", "1");

    // Define to 1 if you have a IPv6 capable working inet_ntop function.
    // #undef HAVE_INET_NTOP

    // Define to 1 if you have a IPv6 capable working inet_pton function.
    ret.defineCMacro("HAVE_INET_PTON", "1");

    // Define to 1 if symbol `sa_family_t' exists
    ret.defineCMacro("HAVE_SA_FAMILY_T", "1");

    // Define to 1 if symbol `ADDRESS_FAMILY' exists
    // #undef HAVE_ADDRESS_FAMILY

    // Define to 1 if you have the <inttypes.h> header file.
    ret.defineCMacro("HAVE_INTTYPES_H", "1");

    // Define to 1 if you have the ioctl function.
    ret.defineCMacro("HAVE_IOCTL", "1");

    // Define to 1 if you have the ioctlsocket function.
    // #undef HAVE_IOCTLSOCKET

    // Define to 1 if you have the IoctlSocket camel case function.
    // #undef HAVE_IOCTLSOCKET_CAMEL

    // Define to 1 if you have a working IoctlSocket camel case FIONBIO function.

    // #undef HAVE_IOCTLSOCKET_CAMEL_FIONBIO

    // Define to 1 if you have a working ioctlsocket FIONBIO function.
    // #undef HAVE_IOCTLSOCKET_FIONBIO

    // Define to 1 if you have a working ioctl FIONBIO function.
    ret.defineCMacro("HAVE_IOCTL_FIONBIO", "1");

    // Define to 1 if you have a working ioctl SIOCGIFADDR function.
    ret.defineCMacro("HAVE_IOCTL_SIOCGIFADDR", "1");

    // Define to 1 if you have the <io.h> header file.
    // #undef HAVE_IO_H

    // if you have the Kerberos4 libraries (including -ldes)
    // #undef HAVE_KRB4

    // Define to 1 if you have the `krb_get_our_ip_for_realm' function.
    // #undef HAVE_KRB_GET_OUR_IP_FOR_REALM

    // Define to 1 if you have the <krb.h> header file.
    // #undef HAVE_KRB_H

    // Define to 1 if you have the lber.h header file.
    // #undef HAVE_LBER_H

    // Define to 1 if you have the ldapssl.h header file.
    // #undef HAVE_LDAPSSL_H

    // Define to 1 if you have the ldap.h header file.
    // #undef HAVE_LDAP_H

    // Use LDAPS implementation
    // #undef HAVE_LDAP_SSL

    // Define to 1 if you have the ldap_ssl.h header file.
    // #undef HAVE_LDAP_SSL_H

    // Define to 1 if you have the `ldap_url_parse' function.
    ret.defineCMacro("HAVE_LDAP_URL_PARSE", "1");

    // Define to 1 if you have the <libgen.h> header file.
    ret.defineCMacro("HAVE_LIBGEN_H", "1");

    // Define to 1 if you have the `idn2' library (-lidn2).
    // #undef HAVE_LIBIDN2

    // Define to 1 if you have the idn2.h header file.
    ret.defineCMacro("HAVE_IDN2_H", "1");

    // Define to 1 if you have the `resolv' library (-lresolv).
    // #undef HAVE_LIBRESOLV

    // Define to 1 if you have the `resolve' library (-lresolve).
    // #undef HAVE_LIBRESOLVE

    // Define to 1 if you have the `socket' library (-lsocket).
    // #undef HAVE_LIBSOCKET

    // if brotli is available
    // #undef HAVE_BROTLI

    // if zstd is available
    // #undef HAVE_ZSTD

    // if your compiler supports LL
    ret.defineCMacro("HAVE_LL", "1");

    // Define to 1 if you have the <locale.h> header file.
    ret.defineCMacro("HAVE_LOCALE_H", "1");

    // Define to 1 if you have a working localtime_r function.
    ret.defineCMacro("HAVE_LOCALTIME_R", "1");

    // Define to 1 if the compiler supports the 'long long' data type.
    ret.defineCMacro("HAVE_LONGLONG", "1");

    // Define to 1 if you have the malloc.h header file.
    ret.defineCMacro("HAVE_MALLOC_H", "1");

    // Define to 1 if you have the <memory.h> header file.
    ret.defineCMacro("HAVE_MEMORY_H", "1");

    // Define to 1 if you have the MSG_NOSIGNAL flag.
    if (!target.isDarwin())
        ret.defineCMacro("HAVE_MSG_NOSIGNAL", "1");

    // Define to 1 if you have the <netdb.h> header file.
    ret.defineCMacro("HAVE_NETDB_H", "1");

    // Define to 1 if you have the <netinet/in.h> header file.
    ret.defineCMacro("HAVE_NETINET_IN_H", "1");

    // Define to 1 if you have the <netinet/tcp.h> header file.
    ret.defineCMacro("HAVE_NETINET_TCP_H", "1");

    // Define to 1 if you have the <linux/tcp.h> header file.
    if (target.isLinux())
        ret.defineCMacro("HAVE_LINUX_TCP_H", "1");

    // Define to 1 if you have the <net/if.h> header file.
    ret.defineCMacro("HAVE_NET_IF_H", "1");

    // Define to 1 if NI_WITHSCOPEID exists and works.
    // #undef HAVE_NI_WITHSCOPEID

    // if you have an old MIT gssapi library, lacking GSS_C_NT_HOSTBASED_SERVICE
    // #undef HAVE_OLD_GSSMIT

    // Define to 1 if you have the <pem.h> header file.
    // #undef HAVE_PEM_H

    // Define to 1 if you have the `pipe' function.
    ret.defineCMacro("HAVE_PIPE", "1");

    // Define to 1 if you have a working poll function.
    ret.defineCMacro("HAVE_POLL", "1");

    // If you have a fine poll
    ret.defineCMacro("HAVE_POLL_FINE", "1");

    // Define to 1 if you have the <poll.h> header file.
    ret.defineCMacro("HAVE_POLL_H", "1");

    // Define to 1 if you have a working POSIX-style strerror_r function.
    ret.defineCMacro("HAVE_POSIX_STRERROR_R", "1");

    // Define to 1 if you have the <pthread.h> header file
    ret.defineCMacro("HAVE_PTHREAD_H", "1");

    // Define to 1 if you have the <pwd.h> header file.
    ret.defineCMacro("HAVE_PWD_H", "1");

    // Define to 1 if you have the `RAND_egd' function.
    // #undef HAVE_RAND_EGD

    // Define to 1 if you have the `RAND_screen' function.
    // #undef HAVE_RAND_SCREEN

    // Define to 1 if you have the `RAND_status' function.
    // #undef HAVE_RAND_STATUS

    // Define to 1 if you have the recv function.
    ret.defineCMacro("HAVE_RECV", "1");

    // Define to 1 if you have the recvfrom function.
    // #undef HAVE_RECVFROM

    // Define to 1 if you have the select function.
    ret.defineCMacro("HAVE_SELECT", "1");

    // Define to 1 if you have the send function.
    ret.defineCMacro("HAVE_SEND", "1");

    // Define to 1 if you have the 'fsetxattr' function.
    ret.defineCMacro("HAVE_FSETXATTR", "1");

    // fsetxattr() takes 5 args
    ret.defineCMacro("HAVE_FSETXATTR_5", "1");

    // fsetxattr() takes 6 args
    // #undef HAVE_FSETXATTR_6

    // Define to 1 if you have the <setjmp.h> header file.
    ret.defineCMacro("HAVE_SETJMP_H", "1");

    // Define to 1 if you have the `setlocale' function.
    ret.defineCMacro("HAVE_SETLOCALE", "1");

    // Define to 1 if you have the `setmode' function.
    // #undef HAVE_SETMODE

    // Define to 1 if you have the `setrlimit' function.
    ret.defineCMacro("HAVE_SETRLIMIT", "1");

    // Define to 1 if you have the setsockopt function.
    ret.defineCMacro("HAVE_SETSOCKOPT", "1");

    // Define to 1 if you have a working setsockopt SO_NONBLOCK function.
    // #undef HAVE_SETSOCKOPT_SO_NONBLOCK

    // Define to 1 if you have the sigaction function.
    ret.defineCMacro("HAVE_SIGACTION", "1");

    // Define to 1 if you have the siginterrupt function.
    ret.defineCMacro("HAVE_SIGINTERRUPT", "1");

    // Define to 1 if you have the signal function.
    ret.defineCMacro("HAVE_SIGNAL", "1");

    // Define to 1 if you have the <signal.h> header file.
    ret.defineCMacro("HAVE_SIGNAL_H", "1");

    // Define to 1 if you have the sigsetjmp function or macro.
    ret.defineCMacro("HAVE_SIGSETJMP", "1");

    // Define to 1 if struct sockaddr_in6 has the sin6_scope_id member
    ret.defineCMacro("HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID", "1");

    // Define to 1 if you have the `socket' function.
    ret.defineCMacro("HAVE_SOCKET", "1");

    // Define to 1 if you have the <stdbool.h> header file.
    ret.defineCMacro("HAVE_STDBOOL_H", "1");

    // Define to 1 if you have the <stdint.h> header file.
    ret.defineCMacro("HAVE_STDINT_H", "1");

    // Define to 1 if you have the <stdio.h> header file.
    ret.defineCMacro("HAVE_STDIO_H", "1");

    // Define to 1 if you have the <stdlib.h> header file.
    ret.defineCMacro("HAVE_STDLIB_H", "1");

    // Define to 1 if you have the strcasecmp function.
    ret.defineCMacro("HAVE_STRCASECMP", "1");

    // Define to 1 if you have the strcasestr function.
    // #undef HAVE_STRCASESTR

    // Define to 1 if you have the strcmpi function.
    // #undef HAVE_STRCMPI

    // Define to 1 if you have the strdup function.
    ret.defineCMacro("HAVE_STRDUP", "1");

    // Define to 1 if you have the strerror_r function.
    ret.defineCMacro("HAVE_STRERROR_R", "1");

    // Define to 1 if you have the stricmp function.
    // #undef HAVE_STRICMP

    // Define to 1 if you have the <strings.h> header file.
    ret.defineCMacro("HAVE_STRINGS_H", "1");

    // Define to 1 if you have the <string.h> header file.
    ret.defineCMacro("HAVE_STRING_H", "1");

    // Define to 1 if you have the strncmpi function.
    // #undef HAVE_STRNCMPI

    // Define to 1 if you have the strnicmp function.
    // #undef HAVE_STRNICMP

    // Define to 1 if you have the <stropts.h> header file.
    // #undef HAVE_STROPTS_H

    // Define to 1 if you have the strstr function.
    ret.defineCMacro("HAVE_STRSTR", "1");

    // Define to 1 if you have the strtok_r function.
    ret.defineCMacro("HAVE_STRTOK_R", "1");

    // Define to 1 if you have the strtoll function.
    ret.defineCMacro("HAVE_STRTOLL", "1");

    // if struct sockaddr_storage is defined
    ret.defineCMacro("HAVE_STRUCT_SOCKADDR_STORAGE", "1");

    // Define to 1 if you have the timeval struct.
    ret.defineCMacro("HAVE_STRUCT_TIMEVAL", "1");

    // Define to 1 if you have the <sys/filio.h> header file.
    // #undef HAVE_SYS_FILIO_H

    // Define to 1 if you have the <sys/ioctl.h> header file.
    ret.defineCMacro("HAVE_SYS_IOCTL_H", "1");

    // Define to 1 if you have the <sys/param.h> header file.
    ret.defineCMacro("HAVE_SYS_PARAM_H", "1");

    // Define to 1 if you have the <sys/poll.h> header file.
    ret.defineCMacro("HAVE_SYS_POLL_H", "1");

    // Define to 1 if you have the <sys/resource.h> header file.
    ret.defineCMacro("HAVE_SYS_RESOURCE_H", "1");

    // Define to 1 if you have the <sys/select.h> header file.
    ret.defineCMacro("HAVE_SYS_SELECT_H", "1");

    // Define to 1 if you have the <sys/socket.h> header file.
    ret.defineCMacro("HAVE_SYS_SOCKET_H", "1");

    // Define to 1 if you have the <sys/sockio.h> header file.
    // #undef HAVE_SYS_SOCKIO_H

    // Define to 1 if you have the <sys/stat.h> header file.
    ret.defineCMacro("HAVE_SYS_STAT_H", "1");

    // Define to 1 if you have the <sys/time.h> header file.
    ret.defineCMacro("HAVE_SYS_TIME_H", "1");

    // Define to 1 if you have the <sys/types.h> header file.
    ret.defineCMacro("HAVE_SYS_TYPES_H", "1");

    // Define to 1 if you have the <sys/uio.h> header file.
    ret.defineCMacro("HAVE_SYS_UIO_H", "1");

    // Define to 1 if you have the <sys/un.h> header file.
    ret.defineCMacro("HAVE_SYS_UN_H", "1");

    // Define to 1 if you have the <sys/utime.h> header file.
    // #undef HAVE_SYS_UTIME_H

    // Define to 1 if you have the <termios.h> header file.
    ret.defineCMacro("HAVE_TERMIOS_H", "1");

    // Define to 1 if you have the <termio.h> header file.
    ret.defineCMacro("HAVE_TERMIO_H", "1");

    // Define to 1 if you have the <time.h> header file.
    ret.defineCMacro("HAVE_TIME_H", "1");

    // Define to 1 if you have the <tld.h> header file.
    // #undef HAVE_TLD_H

    // Define to 1 if you have the `tld_strerror' function.
    // #undef HAVE_TLD_STRERROR

    // Define to 1 if you have the `uname' function.
    ret.defineCMacro("HAVE_UNAME", "1");

    // Define to 1 if you have the <unistd.h> header file.
    ret.defineCMacro("HAVE_UNISTD_H", "1");

    // Define to 1 if you have the `utime' function.
    ret.defineCMacro("HAVE_UTIME", "1");

    // Define to 1 if you have the `utimes' function.
    ret.defineCMacro("HAVE_UTIMES", "1");

    // Define to 1 if you have the <utime.h> header file.
    ret.defineCMacro("HAVE_UTIME_H", "1");

    // Define to 1 if compiler supports C99 variadic macro style.
    ret.defineCMacro("HAVE_VARIADIC_MACROS_C99", "1");

    // Define to 1 if compiler supports old gcc variadic macro style.
    ret.defineCMacro("HAVE_VARIADIC_MACROS_GCC", "1");

    // Define to 1 if you have the winber.h header file.
    // #undef HAVE_WINBER_H

    // Define to 1 if you have the windows.h header file.
    // #undef HAVE_WINDOWS_H

    // Define to 1 if you have the winldap.h header file.
    // #undef HAVE_WINLDAP_H

    // Define to 1 if you have the winsock2.h header file.
    // #undef HAVE_WINSOCK2_H

    // Define this symbol if your OS supports changing the contents of argv
    // #undef HAVE_WRITABLE_ARGV

    // Define to 1 if you have the writev function.
    // #undef HAVE_WRITEV

    // Define to 1 if you have the ws2tcpip.h header file.
    // #undef HAVE_WS2TCPIP_H

    // Define to 1 if you have the <x509.h> header file.
    // #undef HAVE_X509_H

    // Define if you have the <process.h> header file.
    // #undef HAVE_PROCESS_H

    // Define to the sub-directory in which libtool stores uninstalled libraries.

    // #undef LT_OBJDIR

    // If you lack a fine basename() prototype
    // #undef NEED_BASENAME_PROTO

    // Define to 1 if you need the lber.h header file even with ldap.h
    // #undef NEED_LBER_H

    // Define to 1 if you need the malloc.h header file even with stdlib.h
    // #undef NEED_MALLOC_H

    // Define to 1 if _REENTRANT preprocessor symbol must be defined.
    // #undef NEED_REENTRANT

    // cpu-machine-OS
    ret.defineCMacro("OS", "\"Linux\"");

    // Name of package
    // #undef PACKAGE

    // Define to the address where bug reports for this package should be sent.
    // #undef PACKAGE_BUGREPORT

    // Define to the full name of this package.
    // #undef PACKAGE_NAME

    // Define to the full name and version of this package.
    // #undef PACKAGE_STRING

    // Define to the one symbol short name of this package.
    // #undef PACKAGE_TARNAME

    // Define to the version of this package.
    // #undef PACKAGE_VERSION

    // a suitable file to read random data from
    ret.defineCMacro("RANDOM_FILE", "\"/dev/urandom\"");

    // Define to the type of arg 1 for recvfrom.
    // #undef RECVFROM_TYPE_ARG1

    // Define to the type pointed by arg 2 for recvfrom.
    // #undef RECVFROM_TYPE_ARG2

    // Define to 1 if the type pointed by arg 2 for recvfrom is void.
    // #undef RECVFROM_TYPE_ARG2_IS_VOID

    // Define to the type of arg 3 for recvfrom.
    // #undef RECVFROM_TYPE_ARG3

    // Define to the type of arg 4 for recvfrom.
    // #undef RECVFROM_TYPE_ARG4

    // Define to the type pointed by arg 5 for recvfrom.
    // #undef RECVFROM_TYPE_ARG5

    // Define to 1 if the type pointed by arg 5 for recvfrom is void.
    // #undef RECVFROM_TYPE_ARG5_IS_VOID

    // Define to the type pointed by arg 6 for recvfrom.
    // #undef RECVFROM_TYPE_ARG6

    // Define to 1 if the type pointed by arg 6 for recvfrom is void.
    // #undef RECVFROM_TYPE_ARG6_IS_VOID

    // Define to the function return type for recvfrom.
    // #undef RECVFROM_TYPE_RETV

    // Define to the type of arg 1 for recv.
    ret.defineCMacro("RECV_TYPE_ARG1", "int");

    // Define to the type of arg 2 for recv.
    ret.defineCMacro("RECV_TYPE_ARG2", "void *");

    // Define to the type of arg 3 for recv.
    ret.defineCMacro("RECV_TYPE_ARG3", "size_t");

    // Define to the type of arg 4 for recv.
    ret.defineCMacro("RECV_TYPE_ARG4", "int");

    // Define to the function return type for recv.
    ret.defineCMacro("RECV_TYPE_RETV", "ssize_t");

    // Define to the type qualifier of arg 5 for select.
    // #undef SELECT_QUAL_ARG5

    // Define to the type of arg 1 for select.
    // #undef SELECT_TYPE_ARG1

    // Define to the type of args 2, 3 and 4 for select.
    // #undef SELECT_TYPE_ARG234

    // Define to the type of arg 5 for select.
    // #undef SELECT_TYPE_ARG5

    // Define to the function return type for select.
    // #undef SELECT_TYPE_RETV

    // Define to the type qualifier of arg 2 for send.
    ret.defineCMacro("SEND_QUAL_ARG2", "const");

    // Define to the type of arg 1 for send.
    ret.defineCMacro("SEND_TYPE_ARG1", "int");

    // Define to the type of arg 2 for send.
    ret.defineCMacro("SEND_TYPE_ARG2", "void *");

    // Define to the type of arg 3 for send.
    ret.defineCMacro("SEND_TYPE_ARG3", "size_t");

    // Define to the type of arg 4 for send.
    ret.defineCMacro("SEND_TYPE_ARG4", "int");

    // Define to the function return type for send.
    ret.defineCMacro("SEND_TYPE_RETV", "ssize_t");

    // Note: SIZEOF_* variables are fetched with CMake through check_type_size().
    // As per CMake documentation on CheckTypeSize, C preprocessor code is
    // generated by CMake into SIZEOF_*_CODE. This is what we use in the
    // following statements.
    //
    // Reference: https://cmake.org/cmake/help/latest/module/CheckTypeSize.html

    // The size of `int', as computed by sizeof.
    ret.defineCMacro("SIZEOF_INT", "4");

    // The size of `short', as computed by sizeof.
    ret.defineCMacro("SIZEOF_SHORT", "2");

    // The size of `long', as computed by sizeof.
    ret.defineCMacro("SIZEOF_LONG", "8");

    // The size of `off_t', as computed by sizeof.
    ret.defineCMacro("SIZEOF_OFF_T", "8");

    // The size of `curl_off_t', as computed by sizeof.
    ret.defineCMacro("SIZEOF_CURL_OFF_T", "8");

    // The size of `size_t', as computed by sizeof.
    ret.defineCMacro("SIZEOF_SIZE_T", "8");

    // The size of `time_t', as computed by sizeof.
    ret.defineCMacro("SIZEOF_TIME_T", "8");

    // Define to 1 if you have the ANSI C header files.
    ret.defineCMacro("STDC_HEADERS", "1");

    // Define to the type of arg 3 for strerror_r.
    // #undef STRERROR_R_TYPE_ARG3

    // Define to 1 if you can safely include both <sys/time.h> and <time.h>.
    ret.defineCMacro("TIME_WITH_SYS_TIME", "1");

    // Define if you want to enable c-ares support
    // #undef USE_ARES

    // Define if you want to enable POSIX threaded DNS lookup
    ret.defineCMacro("USE_THREADS_POSIX", "1");

    // if libSSH2 is in use
    ret.defineCMacro("USE_LIBSSH2", "1");

    // If you want to build curl with the built-in manual
    // #undef USE_MANUAL

    // if NSS is enabled
    // #undef USE_NSS

    // if you have the PK11_CreateManagedGenericObject function
    // #undef HAVE_PK11_CREATEMANAGEDGENERICOBJECT

    // if you want to use OpenLDAP code instead of legacy ldap implementation
    // #undef USE_OPENLDAP

    // to enable NGHTTP2
    // #undef USE_NGHTTP2

    // to enable NGTCP2
    // #undef USE_NGTCP2

    // to enable NGHTTP3
    // #undef USE_NGHTTP3

    // to enable quiche
    // #undef USE_QUICHE

    // Define to 1 if you have the quiche_conn_set_qlog_fd function.
    // #undef HAVE_QUICHE_CONN_SET_QLOG_FD

    // if Unix domain sockets are enabled
    ret.defineCMacro("USE_UNIX_SOCKETS", null);

    // Define to 1 if you are building a Windows target with large file support.
    // #undef USE_WIN32_LARGE_FILES

    // to enable SSPI support
    // #undef USE_WINDOWS_SSPI

    // to enable Windows SSL
    // #undef USE_SCHANNEL

    // enable multiple SSL backends
    // #undef CURL_WITH_MULTI_SSL

    // Define to 1 if using yaSSL in OpenSSL compatibility mode.
    // #undef USE_YASSLEMUL

    // Version number of package
    // #undef VERSION

    // Define to 1 if OS is AIX.
    //#ifndef _ALL_SOURCE
    //#  undef _ALL_SOURCE
    //#endif

    // Number of bits in a file offset, on hosts where this is settable.
    ret.defineCMacro("_FILE_OFFSET_BITS", "64");

    // Define for large files, on AIX-style hosts.
    // #undef _LARGE_FILES

    // define this if you need it to compile thread-safe code
    // #undef _THREAD_SAFE

    // Define to empty if `const' does not conform to ANSI C.
    // #undef const

    // Type to use in place of in_addr_t when system does not provide it.
    // #undef in_addr_t

    // Define to `__inline__' or `__inline' if that's what the C compiler
    // calls it, or to nothing if 'inline' is not supported under any name.
    //#ifndef __cplusplus
    //#undef inline
    //#endif

    // Define to `unsigned int' if <sys/types.h> does not define.
    // #undef size_t

    // the signed version of size_t
    // #undef ssize_t

    // Define to 1 if you have the mach_absolute_time function.
    // #undef HAVE_MACH_ABSOLUTE_TIME

    // to enable Windows IDN
    // #undef USE_WIN32_IDN

    // to make the compiler know the prototypes of Windows IDN APIs
    // #undef WANT_IDN_PROTOTYPES

    return Library{ .step = ret, .exported_defines = exported_defines.toOwnedSlice() };
}

const srcs = &.{
    root_path ++ "curl/lib/hostcheck.c",
    root_path ++ "curl/lib/curl_gethostname.c",
    root_path ++ "curl/lib/strerror.c",
    root_path ++ "curl/lib/strdup.c",
    root_path ++ "curl/lib/asyn-ares.c",
    root_path ++ "curl/lib/pop3.c",
    root_path ++ "curl/lib/bufref.c",
    root_path ++ "curl/lib/rename.c",
    root_path ++ "curl/lib/nwlib.c",
    root_path ++ "curl/lib/file.c",
    root_path ++ "curl/lib/curl_gssapi.c",
    root_path ++ "curl/lib/ldap.c",
    root_path ++ "curl/lib/socketpair.c",
    root_path ++ "curl/lib/system_win32.c",
    root_path ++ "curl/lib/http_aws_sigv4.c",
    root_path ++ "curl/lib/content_encoding.c",
    root_path ++ "curl/lib/vquic/ngtcp2.c",
    root_path ++ "curl/lib/vquic/quiche.c",
    root_path ++ "curl/lib/vquic/vquic.c",
    root_path ++ "curl/lib/ftp.c",
    root_path ++ "curl/lib/curl_ntlm_wb.c",
    root_path ++ "curl/lib/curl_ntlm_core.c",
    root_path ++ "curl/lib/hostip.c",
    root_path ++ "curl/lib/urlapi.c",
    root_path ++ "curl/lib/curl_get_line.c",
    root_path ++ "curl/lib/vtls/mesalink.c",
    root_path ++ "curl/lib/vtls/mbedtls_threadlock.c",
    root_path ++ "curl/lib/vtls/nss.c",
    root_path ++ "curl/lib/vtls/gskit.c",
    root_path ++ "curl/lib/vtls/wolfssl.c",
    root_path ++ "curl/lib/vtls/keylog.c",
    root_path ++ "curl/lib/vtls/rustls.c",
    root_path ++ "curl/lib/vtls/vtls.c",
    root_path ++ "curl/lib/vtls/gtls.c",
    root_path ++ "curl/lib/vtls/schannel.c",
    root_path ++ "curl/lib/vtls/schannel_verify.c",
    root_path ++ "curl/lib/vtls/sectransp.c",
    root_path ++ "curl/lib/vtls/openssl.c",
    root_path ++ "curl/lib/vtls/mbedtls.c",
    root_path ++ "curl/lib/vtls/bearssl.c",
    root_path ++ "curl/lib/parsedate.c",
    root_path ++ "curl/lib/sendf.c",
    root_path ++ "curl/lib/altsvc.c",
    root_path ++ "curl/lib/krb5.c",
    root_path ++ "curl/lib/curl_rtmp.c",
    root_path ++ "curl/lib/curl_ctype.c",
    root_path ++ "curl/lib/inet_pton.c",
    root_path ++ "curl/lib/pingpong.c",
    root_path ++ "curl/lib/mime.c",
    root_path ++ "curl/lib/vauth/krb5_gssapi.c",
    root_path ++ "curl/lib/vauth/krb5_sspi.c",
    root_path ++ "curl/lib/vauth/spnego_sspi.c",
    root_path ++ "curl/lib/vauth/digest.c",
    root_path ++ "curl/lib/vauth/ntlm_sspi.c",
    root_path ++ "curl/lib/vauth/vauth.c",
    root_path ++ "curl/lib/vauth/gsasl.c",
    root_path ++ "curl/lib/vauth/cram.c",
    root_path ++ "curl/lib/vauth/oauth2.c",
    root_path ++ "curl/lib/vauth/digest_sspi.c",
    root_path ++ "curl/lib/vauth/cleartext.c",
    root_path ++ "curl/lib/vauth/spnego_gssapi.c",
    root_path ++ "curl/lib/vauth/ntlm.c",
    root_path ++ "curl/lib/version_win32.c",
    root_path ++ "curl/lib/multi.c",
    root_path ++ "curl/lib/http_ntlm.c",
    root_path ++ "curl/lib/curl_sspi.c",
    root_path ++ "curl/lib/md5.c",
    root_path ++ "curl/lib/dict.c",
    root_path ++ "curl/lib/http.c",
    root_path ++ "curl/lib/curl_des.c",
    root_path ++ "curl/lib/memdebug.c",
    root_path ++ "curl/lib/non-ascii.c",
    root_path ++ "curl/lib/transfer.c",
    root_path ++ "curl/lib/inet_ntop.c",
    root_path ++ "curl/lib/slist.c",
    root_path ++ "curl/lib/http_negotiate.c",
    root_path ++ "curl/lib/http_digest.c",
    root_path ++ "curl/lib/vssh/wolfssh.c",
    root_path ++ "curl/lib/vssh/libssh.c",
    root_path ++ "curl/lib/vssh/libssh2.c",
    root_path ++ "curl/lib/hsts.c",
    root_path ++ "curl/lib/escape.c",
    root_path ++ "curl/lib/hostsyn.c",
    root_path ++ "curl/lib/speedcheck.c",
    root_path ++ "curl/lib/asyn-thread.c",
    root_path ++ "curl/lib/curl_addrinfo.c",
    root_path ++ "curl/lib/nwos.c",
    root_path ++ "curl/lib/tftp.c",
    root_path ++ "curl/lib/version.c",
    root_path ++ "curl/lib/rand.c",
    root_path ++ "curl/lib/psl.c",
    root_path ++ "curl/lib/imap.c",
    root_path ++ "curl/lib/mqtt.c",
    root_path ++ "curl/lib/share.c",
    root_path ++ "curl/lib/doh.c",
    root_path ++ "curl/lib/curl_range.c",
    root_path ++ "curl/lib/openldap.c",
    root_path ++ "curl/lib/getinfo.c",
    root_path ++ "curl/lib/select.c",
    root_path ++ "curl/lib/base64.c",
    root_path ++ "curl/lib/curl_sasl.c",
    root_path ++ "curl/lib/curl_endian.c",
    root_path ++ "curl/lib/connect.c",
    root_path ++ "curl/lib/fileinfo.c",
    root_path ++ "curl/lib/telnet.c",
    root_path ++ "curl/lib/x509asn1.c",
    root_path ++ "curl/lib/conncache.c",
    root_path ++ "curl/lib/strcase.c",
    root_path ++ "curl/lib/if2ip.c",
    root_path ++ "curl/lib/gopher.c",
    root_path ++ "curl/lib/ftplistparser.c",
    root_path ++ "curl/lib/setopt.c",
    root_path ++ "curl/lib/idn_win32.c",
    root_path ++ "curl/lib/strtoofft.c",
    root_path ++ "curl/lib/hmac.c",
    root_path ++ "curl/lib/getenv.c",
    root_path ++ "curl/lib/smb.c",
    root_path ++ "curl/lib/dotdot.c",
    root_path ++ "curl/lib/curl_threads.c",
    root_path ++ "curl/lib/md4.c",
    root_path ++ "curl/lib/easygetopt.c",
    root_path ++ "curl/lib/curl_fnmatch.c",
    root_path ++ "curl/lib/sha256.c",
    root_path ++ "curl/lib/cookie.c",
    root_path ++ "curl/lib/amigaos.c",
    root_path ++ "curl/lib/progress.c",
    root_path ++ "curl/lib/nonblock.c",
    root_path ++ "curl/lib/llist.c",
    root_path ++ "curl/lib/hostip6.c",
    root_path ++ "curl/lib/dynbuf.c",
    root_path ++ "curl/lib/warnless.c",
    root_path ++ "curl/lib/hostasyn.c",
    root_path ++ "curl/lib/http_chunks.c",
    root_path ++ "curl/lib/wildcard.c",
    root_path ++ "curl/lib/strtok.c",
    root_path ++ "curl/lib/curl_memrchr.c",
    root_path ++ "curl/lib/rtsp.c",
    root_path ++ "curl/lib/http2.c",
    root_path ++ "curl/lib/socks.c",
    root_path ++ "curl/lib/curl_path.c",
    root_path ++ "curl/lib/curl_multibyte.c",
    root_path ++ "curl/lib/http_proxy.c",
    root_path ++ "curl/lib/formdata.c",
    root_path ++ "curl/lib/netrc.c",
    root_path ++ "curl/lib/socks_sspi.c",
    root_path ++ "curl/lib/mprintf.c",
    root_path ++ "curl/lib/easyoptions.c",
    root_path ++ "curl/lib/easy.c",
    root_path ++ "curl/lib/c-hyper.c",
    root_path ++ "curl/lib/hostip4.c",
    root_path ++ "curl/lib/timeval.c",
    root_path ++ "curl/lib/smtp.c",
    root_path ++ "curl/lib/splay.c",
    root_path ++ "curl/lib/socks_gssapi.c",
    root_path ++ "curl/lib/url.c",
    root_path ++ "curl/lib/hash.c",
};
