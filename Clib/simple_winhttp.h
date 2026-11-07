/*
 * simple_winhttp.h - Synchronous HTTP/HTTPS exchange for Eiffel, on WinHTTP.
 *
 * Promoted from simple_ocr_capture's ocr_http.h (proven in the field) and
 * extended for the simple_chat client's transport contract:
 *
 *   - HTTPS through SChannel (WINHTTP_FLAG_SECURE), certificate validation
 *     ON by default, with an explicit opt-out for lab rigs.
 *   - Redirects are NEVER followed: WINHTTP_OPTION_REDIRECT_POLICY_NEVER is
 *     set on the session before any request, so a 3xx comes back as the
 *     reply and an Authorization header is never re-sent to whatever host
 *     the reply names.
 *   - Caller-supplied request headers (one CRLF-joined block).
 *   - Separate connect and receive timeouts (the receive one must outlive a
 *     25 s long-poll).
 *   - A hard cap on the response body: beyond it the exchange fails cleanly
 *     (out_overflow = 1) instead of growing without bound.
 *   - The raw response headers come back too (status line + CRLF lines).
 *   - No static state: status / Win32 error / overflow travel through out
 *     parameters, so concurrent SCOOP processors never race on globals.
 *
 * Why not simple_http / curl_http_client: that path resolves libcurl.dll at
 * runtime, and libcurl.dll ships only inside EiffelStudio's
 * studio\spec\win64\bin, which is not on PATH. A finalized binary therefore
 * fails even though the request never left the process. WinHTTP is part of
 * every supported Windows, needs no redistributable, and is linked here via
 * #pragma comment so the ECF needs no external_library entry.
 *
 * macOS and Linux use libcurl instead; see the second half of this file.
 *
 * Following Eric Bezault's recommended pattern: implementations in .h file,
 * called from Eiffel inline C with a use directive.
 *
 * Copyright (c) 2026 Larry Rix - MIT License
 */

#ifndef SIMPLE_WINHTTP_H
#define SIMPLE_WINHTTP_H

#if defined(_WIN32) || defined(EIF_WINDOWS)

#include <windows.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "winhttp.lib")

/*
 * <winhttp.h> is deliberately NOT included, and the entry points used here
 * are declared directly instead.
 *
 * The Eiffel C build hard-codes -D_WIN32_WINNT=0x0500 (Windows 2000) and
 * -DWIN32_LEAN_AND_MEAN on the cl command line. winhttp.h declares
 * WINHTTP_CONNECTION_INFO with SOCKADDR_STORAGE members, but <ws2def.h>
 * compiles that type out below _WIN32_WINNT 0x0501, so the header fails
 * with a syntax error on SOCKADDR_STORAGE. Raising the version inside this
 * file does not help, because the Winsock headers have already been
 * processed at 0x0500 earlier in the generated translation unit.
 *
 * Declaring the functions we call keeps the fix local and makes the build
 * independent of which Windows SDK is installed. The symbols still come
 * from winhttp.lib, so the ABI is the real one. (Pattern proven in
 * simple_ocr_capture.)
 */
typedef LPVOID          HINTERNET;
typedef WORD            INTERNET_PORT;

#define WINHTTP_ACCESS_TYPE_NO_PROXY            1
#define WINHTTP_QUERY_STATUS_CODE               19
#define WINHTTP_QUERY_RAW_HEADERS_CRLF          22
#define WINHTTP_QUERY_FLAG_NUMBER               0x20000000
#define WINHTTP_FLAG_SECURE                     0x00800000

#define WINHTTP_OPTION_SECURITY_FLAGS           31
#define WINHTTP_OPTION_REDIRECT_POLICY          88
#define WINHTTP_OPTION_REDIRECT_POLICY_NEVER    0

#define SECURITY_FLAG_IGNORE_UNKNOWN_CA         0x00000100
#define SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE   0x00000200
#define SECURITY_FLAG_IGNORE_CERT_CN_INVALID    0x00001000
#define SECURITY_FLAG_IGNORE_CERT_DATE_INVALID  0x00002000

/* Sentinels winhttp.h would normally supply; all of them are simply NULL. */
#define WINHTTP_NO_PROXY_NAME           NULL
#define WINHTTP_NO_PROXY_BYPASS         NULL
#define WINHTTP_NO_REFERER              NULL
#define WINHTTP_DEFAULT_ACCEPT_TYPES    NULL
#define WINHTTP_HEADER_NAME_BY_INDEX    NULL
#define WINHTTP_NO_HEADER_INDEX         NULL
#define WINHTTP_NO_ADDITIONAL_HEADERS   NULL
#define WINHTTP_NO_REQUEST_DATA         NULL

HINTERNET WINAPI WinHttpOpen (LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
HINTERNET WINAPI WinHttpConnect (HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
HINTERNET WINAPI WinHttpOpenRequest (HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR *, DWORD);
BOOL      WINAPI WinHttpSetTimeouts (HINTERNET, int, int, int, int);
BOOL      WINAPI WinHttpSetOption (HINTERNET, DWORD, LPVOID, DWORD);
BOOL      WINAPI WinHttpSendRequest (HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
BOOL      WINAPI WinHttpReceiveResponse (HINTERNET, LPVOID);
BOOL      WINAPI WinHttpQueryHeaders (HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
BOOL      WINAPI WinHttpQueryDataAvailable (HINTERNET, LPDWORD);
BOOL      WINAPI WinHttpReadData (HINTERNET, LPVOID, DWORD, LPDWORD);
BOOL      WINAPI WinHttpCloseHandle (HINTERNET);

/* UTF-8 -> wide. Caller frees with free(). NULL on failure. */
static wchar_t *swhttp_widen (const char *s)
{
    int      n;
    wchar_t *w;

    if (s == NULL) return NULL;
    n = MultiByteToWideChar (CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    w = (wchar_t *) malloc (sizeof (wchar_t) * (size_t) n);
    if (w == NULL) return NULL;
    if (MultiByteToWideChar (CP_UTF8, 0, s, -1, w, n) <= 0) {
        free (w);
        return NULL;
    }
    return w;
}

/* Wide -> UTF-8. Caller frees with free(). NULL on failure. */
static char *swhttp_narrow (const wchar_t *w)
{
    int   n;
    char *s;

    if (w == NULL) return NULL;
    n = WideCharToMultiByte (CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    s = (char *) malloc ((size_t) n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte (CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) {
        free (s);
        return NULL;
    }
    return s;
}

/*
 * One synchronous HTTP(S) exchange.
 *
 *   a_verb            "GET", "POST", ... (ASCII)
 *   a_host            host name or address (no scheme, no port)
 *   a_port            1..65535
 *   a_path            absolute path, query included ("/rooms/1/wait?...")
 *   a_use_tls         0 = http, 1 = https (WINHTTP_FLAG_SECURE)
 *   a_headers         CRLF-joined "Name: value\r\n" block, or NULL for none
 *   a_body            request body bytes, or NULL for none
 *   a_body_len        byte count of a_body (0 when NULL)
 *   a_connect_ms      resolve + connect timeout, milliseconds
 *   a_receive_ms      send + receive timeout, milliseconds (long-poll: > 30000)
 *   a_max_body        hard cap on the response body, bytes
 *   a_validate_certs  1 = full certificate validation (default posture),
 *                     0 = ignore certificate errors (lab rigs only)
 *
 * Returns a malloc'd, NUL-terminated buffer holding the response body, or
 * NULL when no exchange happened. Out parameters:
 *
 *   *a_out_len        body length in bytes
 *   *a_out_headers    malloc'd, NUL-terminated raw response headers
 *                     (status line + CRLF header lines), possibly "" -
 *                     only allocated on success; caller frees
 *   *a_out_status     HTTP status code, 0 when none arrived
 *   *a_out_winerr     Win32 error code when the exchange failed, else 0
 *   *a_out_overflow   1 when the body exceeded a_max_body, else 0
 *
 * Redirects: before any request the session is switched to
 * WINHTTP_OPTION_REDIRECT_POLICY_NEVER, so a 3xx IS the answer - the
 * Location header comes back in *a_out_headers and nothing is re-sent.
 * If that option cannot be set the exchange is abandoned rather than run
 * with WinHTTP's default follow-redirects policy.
 *
 * The response is read in a loop because WinHttpQueryDataAvailable reports
 * only what is buffered right now, not the whole body; a single read would
 * silently truncate a large reply.
 *
 * Every handle is closed on every path (single cleanup exit), so the caller
 * never manages Win32 state.
 */
static char *swhttp_request (const char *a_verb, const char *a_host, int a_port,
                             const char *a_path, int a_use_tls,
                             const char *a_headers,
                             const char *a_body, int a_body_len,
                             int a_connect_ms, int a_receive_ms,
                             int a_max_body, int a_validate_certs,
                             int *a_out_len, char **a_out_headers,
                             int *a_out_status, int *a_out_winerr,
                             int *a_out_overflow)
{
    HINTERNET hSession = NULL, hConnect = NULL, hRequest = NULL;
    wchar_t  *wHost = NULL, *wPath = NULL, *wVerb = NULL, *wHeaders = NULL;
    wchar_t  *wRaw = NULL;
    char     *buffer = NULL, *grown = NULL, *headers8 = NULL;
    DWORD     total = 0, avail = 0, got = 0, cap = 0;
    DWORD     status = 0, statusLen = sizeof (DWORD);
    DWORD     rawLen = 0, policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    DWORD     ignore_flags = SECURITY_FLAG_IGNORE_UNKNOWN_CA
                           | SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE
                           | SECURITY_FLAG_IGNORE_CERT_CN_INVALID
                           | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID;
    BOOL      ok = FALSE;
    int       overflowed = 0;

    if (a_out_len != NULL)      *a_out_len = 0;
    if (a_out_headers != NULL)  *a_out_headers = NULL;
    if (a_out_status != NULL)   *a_out_status = 0;
    if (a_out_winerr != NULL)   *a_out_winerr = 0;
    if (a_out_overflow != NULL) *a_out_overflow = 0;

    wHost = swhttp_widen (a_host);
    wPath = swhttp_widen (a_path);
    wVerb = swhttp_widen (a_verb);
    if (wHost == NULL || wPath == NULL || wVerb == NULL) goto cleanup;
    if (a_headers != NULL && a_headers[0] != '\0') {
        wHeaders = swhttp_widen (a_headers);
        if (wHeaders == NULL) goto cleanup;
    }

    hSession = WinHttpOpen (L"simple_winhttp/0.1",
                            WINHTTP_ACCESS_TYPE_NO_PROXY,
                            WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (hSession == NULL) goto cleanup;

    /* The no-redirect guarantee. Refuse to continue without it. */
    if (!WinHttpSetOption (hSession, WINHTTP_OPTION_REDIRECT_POLICY,
                           &policy, sizeof (policy))) goto cleanup;

    WinHttpSetTimeouts (hSession, a_connect_ms, a_connect_ms,
                        a_receive_ms, a_receive_ms);

    hConnect = WinHttpConnect (hSession, wHost, (INTERNET_PORT) a_port, 0);
    if (hConnect == NULL) goto cleanup;

    hRequest = WinHttpOpenRequest (hConnect, wVerb, wPath, NULL,
                                   WINHTTP_NO_REFERER,
                                   WINHTTP_DEFAULT_ACCEPT_TYPES,
                                   a_use_tls ? WINHTTP_FLAG_SECURE : 0);
    if (hRequest == NULL) goto cleanup;

    if (a_use_tls && !a_validate_certs) {
        /* Lab rigs with self-signed certificates; never the default. */
        if (!WinHttpSetOption (hRequest, WINHTTP_OPTION_SECURITY_FLAGS,
                               &ignore_flags, sizeof (ignore_flags))) goto cleanup;
    }

    ok = WinHttpSendRequest (hRequest,
                             wHeaders != NULL ? wHeaders : WINHTTP_NO_ADDITIONAL_HEADERS,
                             wHeaders != NULL ? (DWORD) -1L : 0,
                             (a_body != NULL && a_body_len > 0) ? (LPVOID) a_body : WINHTTP_NO_REQUEST_DATA,
                             (a_body != NULL && a_body_len > 0) ? (DWORD) a_body_len : 0,
                             (a_body != NULL && a_body_len > 0) ? (DWORD) a_body_len : 0,
                             0);
    if (!ok) goto cleanup;

    ok = WinHttpReceiveResponse (hRequest, NULL);
    if (!ok) goto cleanup;

    if (WinHttpQueryHeaders (hRequest,
                             WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                             WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen,
                             WINHTTP_NO_HEADER_INDEX)) {
        if (a_out_status != NULL) *a_out_status = (int) status;
    }

    /* Raw response headers: size probe, then fetch. Optional - a failure
       here leaves headers empty but the body still counts. */
    rawLen = 0;
    WinHttpQueryHeaders (hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                         WINHTTP_HEADER_NAME_BY_INDEX, NULL, &rawLen,
                         WINHTTP_NO_HEADER_INDEX);
    if (rawLen > 0) {
        wRaw = (wchar_t *) malloc (rawLen);
        if (wRaw != NULL) {
            if (WinHttpQueryHeaders (hRequest, WINHTTP_QUERY_RAW_HEADERS_CRLF,
                                     WINHTTP_HEADER_NAME_BY_INDEX, wRaw, &rawLen,
                                     WINHTTP_NO_HEADER_INDEX)) {
                headers8 = swhttp_narrow (wRaw);
            }
            free (wRaw);
            wRaw = NULL;
        }
    }
    if (headers8 == NULL) {
        headers8 = (char *) malloc (1);
        if (headers8 == NULL) goto cleanup;
        headers8[0] = '\0';
    }

    cap = 65536;
    if ((int) cap > a_max_body + 1) cap = (DWORD) (a_max_body + 1);
    buffer = (char *) malloc (cap);
    if (buffer == NULL) goto cleanup;

    for (;;) {
        avail = 0;
        if (!WinHttpQueryDataAvailable (hRequest, &avail)) goto cleanup;
        if (avail == 0) break;

        if (total + avail > (DWORD) a_max_body) {
            overflowed = 1;
            goto cleanup;
        }
        if (total + avail + 1 > cap) {
            while (total + avail + 1 > cap) cap *= 2;
            if (cap > (DWORD) a_max_body + 1) cap = (DWORD) (a_max_body + 1);
            grown = (char *) realloc (buffer, cap);
            if (grown == NULL) goto cleanup;
            buffer = grown;
        }

        got = 0;
        if (!WinHttpReadData (hRequest, buffer + total, avail, &got)) goto cleanup;
        if (got == 0) break;
        total += got;
    }

    buffer[total] = '\0';
    if (a_out_len != NULL) *a_out_len = (int) total;
    if (a_out_headers != NULL) {
        *a_out_headers = headers8;
    } else {
        free (headers8);
    }

    WinHttpCloseHandle (hRequest);
    WinHttpCloseHandle (hConnect);
    WinHttpCloseHandle (hSession);
    free (wHost);
    free (wPath);
    free (wVerb);
    if (wHeaders) free (wHeaders);
    return buffer;

cleanup:
    if (a_out_winerr != NULL)   *a_out_winerr = overflowed ? 0 : (int) GetLastError ();
    if (a_out_overflow != NULL) *a_out_overflow = overflowed;
    if (buffer)   free (buffer);
    if (headers8) free (headers8);
    if (wRaw)     free (wRaw);
    if (hRequest) WinHttpCloseHandle (hRequest);
    if (hConnect) WinHttpCloseHandle (hConnect);
    if (hSession) WinHttpCloseHandle (hSession);
    if (wHost)    free (wHost);
    if (wPath)    free (wPath);
    if (wVerb)    free (wVerb);
    if (wHeaders) free (wHeaders);
    return NULL;
}

static void swhttp_free (char *p) { if (p) free (p); }

#else
/* ============ macOS and Linux: libcurl ============ */

/*
 * The same contract as the Windows half, on libcurl (part of macOS; on Linux
 * the libcurl development package). Redirects are off, the proxy is off, the
 * body cap holds, and certificates are checked unless the caller opted out.
 * Only what the caller asked for is sent: curl's default Accept, Content-Type
 * and Expect headers are suppressed, since WinHTTP adds none of them.
 *
 * *a_out_winerr carries the WinHTTP number for the same failure, so
 * SIMPLE_WINHTTP.failure_description and its callers read one set of codes.
 *
 * The receive timeout is an inactivity limit, as in WinHTTP, not a limit on
 * the whole exchange. libcurl counts it in whole seconds.
 *
 * CURLOPT_NOSIGNAL keeps libcurl from touching signals, which SCOOP threads
 * and the Eiffel runtime both need. No Eiffel memory is touched.
 */

#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <strings.h>

#define SWHTTP_ERROR_TIMEOUT       12002
#define SWHTTP_ERROR_INTERNAL      12004
#define SWHTTP_ERROR_NAME          12007
#define SWHTTP_ERROR_CANNOT_CONNECT 12029
#define SWHTTP_ERROR_CONNECTION    12030
#define SWHTTP_ERROR_SECURE        12175

typedef struct {
    char   *data;
    size_t  count;
    size_t  capacity;
    size_t  limit;       /* 0: none */
    int     overflowed;
    int     out_of_memory;
} swhttp_buffer;

static int swhttp_append (swhttp_buffer *b, const char *a_bytes, size_t a_count)
{
    size_t l_capacity = b->capacity ? b->capacity : 4096;
    char  *l_grown;

    while (b->count + a_count + 1 > l_capacity) l_capacity *= 2;
    if (l_capacity != b->capacity) {
        l_grown = (char *) realloc (b->data, l_capacity);
        if (l_grown == NULL) {
            b->out_of_memory = 1;
            return 0;
        }
        b->data = l_grown;
        b->capacity = l_capacity;
    }
    memcpy (b->data + b->count, a_bytes, a_count);
    b->count += a_count;
    b->data[b->count] = '\0';
    return 1;
}

static size_t swhttp_on_body (char *a_bytes, size_t a_size, size_t a_items, void *a_buffer)
{
    swhttp_buffer *b = (swhttp_buffer *) a_buffer;
    size_t l_count = a_size * a_items;

    if (b->limit > 0 && b->count + l_count > b->limit) {
        b->overflowed = 1;
        return 0;
    }
    return swhttp_append (b, a_bytes, l_count) ? l_count : 0;
}

/* Keep the last response's headers: an interim 100 starts a block of its own. */
static size_t swhttp_on_header (char *a_bytes, size_t a_size, size_t a_items, void *a_buffer)
{
    swhttp_buffer *b = (swhttp_buffer *) a_buffer;
    size_t l_count = a_size * a_items;

    if (l_count >= 5 && memcmp (a_bytes, "HTTP/", 5) == 0) b->count = 0;
    return swhttp_append (b, a_bytes, l_count) ? l_count : 0;
}

/* Does the CRLF block `a_headers' set header `a_name'? */
static int swhttp_has_header (const char *a_headers, const char *a_name)
{
    const char *l_line = a_headers;
    size_t      l_name = strlen (a_name);

    while (l_line != NULL && *l_line != '\0') {
        if (strncasecmp (l_line, a_name, l_name) == 0 && l_line[l_name] == ':') return 1;
        l_line = strchr (l_line, '\n');
        if (l_line != NULL) l_line++;
    }
    return 0;
}

/* The CRLF block as a curl list, with curl's defaults suppressed. 0 on failure. */
static int swhttp_header_list (const char *a_headers, struct curl_slist **a_list)
{
    static const char *const l_defaults[] = {"Accept", "Content-Type", "Expect"};
    const char *l_block = a_headers ? a_headers : "";
    const char *l_line = l_block;
    const char *l_end;
    struct curl_slist *l_grown;
    char   *l_copy;
    char    l_suppress[32];
    size_t  l_length;
    int     l_i;

    while (*l_line != '\0') {
        l_end = strchr (l_line, '\n');
        l_length = l_end ? (size_t) (l_end - l_line) : strlen (l_line);
        if (l_length > 0 && l_line[l_length - 1] == '\r') l_length--;
        if (l_length > 0) {
            l_copy = (char *) malloc (l_length + 1);
            if (l_copy == NULL) return 0;
            memcpy (l_copy, l_line, l_length);
            l_copy[l_length] = '\0';
            l_grown = curl_slist_append (*a_list, l_copy);
            free (l_copy);
            if (l_grown == NULL) return 0;
            *a_list = l_grown;
        }
        if (l_end == NULL) break;
        l_line = l_end + 1;
    }
    for (l_i = 0; l_i < 3; l_i++) {
        if (!swhttp_has_header (l_block, l_defaults[l_i])) {
            strcpy (l_suppress, l_defaults[l_i]);
            strcat (l_suppress, ":");
            l_grown = curl_slist_append (*a_list, l_suppress);
            if (l_grown == NULL) return 0;
            *a_list = l_grown;
        }
    }
    return 1;
}

static int swhttp_error_code (CURLcode a_code)
{
    switch (a_code) {
    case CURLE_OPERATION_TIMEDOUT:
        return SWHTTP_ERROR_TIMEOUT;
    case CURLE_COULDNT_RESOLVE_HOST:
    case CURLE_COULDNT_RESOLVE_PROXY:
        return SWHTTP_ERROR_NAME;
    case CURLE_COULDNT_CONNECT:
        return SWHTTP_ERROR_CANNOT_CONNECT;
    case CURLE_SSL_CONNECT_ERROR:
    case CURLE_PEER_FAILED_VERIFICATION:
    case CURLE_SSL_CERTPROBLEM:
    case CURLE_SSL_CIPHER:
    case CURLE_SSL_CACERT_BADFILE:
        return SWHTTP_ERROR_SECURE;
    case CURLE_GOT_NOTHING:
    case CURLE_SEND_ERROR:
    case CURLE_RECV_ERROR:
    case CURLE_PARTIAL_FILE:
        return SWHTTP_ERROR_CONNECTION;
    default:
        return SWHTTP_ERROR_INTERNAL;
    }
}

static void swhttp_global_init (void) { curl_global_init (CURL_GLOBAL_DEFAULT); }

/* See the Windows swhttp_request above for the full contract. */
static char *swhttp_request (const char *a_verb, const char *a_host, int a_port,
                             const char *a_path, int a_use_tls,
                             const char *a_headers,
                             const char *a_body, int a_body_len,
                             int a_connect_ms, int a_receive_ms,
                             int a_max_body, int a_validate_certs,
                             int *a_out_len, char **a_out_headers,
                             int *a_out_status, int *a_out_winerr,
                             int *a_out_overflow)
{
    static pthread_once_t l_once = PTHREAD_ONCE_INIT;
    CURL              *l_curl = NULL;
    struct curl_slist *l_list = NULL;
    swhttp_buffer      l_body, l_headers;
    char              *l_url = NULL;
    size_t             l_url_size;
    long               l_status = 0;
    long               l_idle_seconds = ((long) a_receive_ms + 999) / 1000;
    int                l_ipv6 = strchr (a_host, ':') != NULL;
    int                l_has_body = a_body != NULL && a_body_len > 0;
    int                l_error = SWHTTP_ERROR_INTERNAL;
    CURLcode           l_code;

    if (a_out_len != NULL)      *a_out_len = 0;
    if (a_out_headers != NULL)  *a_out_headers = NULL;
    if (a_out_status != NULL)   *a_out_status = 0;
    if (a_out_winerr != NULL)   *a_out_winerr = 0;
    if (a_out_overflow != NULL) *a_out_overflow = 0;

    memset (&l_body, 0, sizeof (l_body));
    memset (&l_headers, 0, sizeof (l_headers));
    l_body.limit = (size_t) a_max_body;
    /* An empty reply is still a reply: the buffer exists from the start. */
    if (!swhttp_append (&l_body, "", 0) || !swhttp_append (&l_headers, "", 0)) goto cleanup;

    pthread_once (&l_once, swhttp_global_init);
    l_curl = curl_easy_init ();
    if (l_curl == NULL) goto cleanup;
    if (!swhttp_header_list (a_headers, &l_list)) goto cleanup;

    l_url_size = strlen (a_host) + strlen (a_path) + 32;
    l_url = (char *) malloc (l_url_size);
    if (l_url == NULL) goto cleanup;
    snprintf (l_url, l_url_size, "%s://%s%s%s:%d%s", a_use_tls ? "https" : "http",
              l_ipv6 ? "[" : "", a_host, l_ipv6 ? "]" : "", a_port, a_path);

    curl_easy_setopt (l_curl, CURLOPT_URL, l_url);
    curl_easy_setopt (l_curl, CURLOPT_PATH_AS_IS, 1L);
    curl_easy_setopt (l_curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt (l_curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt (l_curl, CURLOPT_PROXY, "");
    curl_easy_setopt (l_curl, CURLOPT_HTTP_VERSION, (long) CURL_HTTP_VERSION_1_1);
    curl_easy_setopt (l_curl, CURLOPT_USERAGENT, "simple_winhttp/0.1");
    curl_easy_setopt (l_curl, CURLOPT_HTTPHEADER, l_list);
    curl_easy_setopt (l_curl, CURLOPT_CONNECTTIMEOUT_MS, (long) a_connect_ms);
    curl_easy_setopt (l_curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt (l_curl, CURLOPT_LOW_SPEED_TIME, l_idle_seconds > 0 ? l_idle_seconds : 1L);
    curl_easy_setopt (l_curl, CURLOPT_SSL_VERIFYPEER, a_validate_certs ? 1L : 0L);
    curl_easy_setopt (l_curl, CURLOPT_SSL_VERIFYHOST, a_validate_certs ? 2L : 0L);
    curl_easy_setopt (l_curl, CURLOPT_WRITEFUNCTION, swhttp_on_body);
    curl_easy_setopt (l_curl, CURLOPT_WRITEDATA, &l_body);
    curl_easy_setopt (l_curl, CURLOPT_HEADERFUNCTION, swhttp_on_header);
    curl_easy_setopt (l_curl, CURLOPT_HEADERDATA, &l_headers);

    if (strcmp (a_verb, "HEAD") == 0) {
        curl_easy_setopt (l_curl, CURLOPT_NOBODY, 1L);
    } else {
        if (l_has_body || strcmp (a_verb, "POST") == 0 || strcmp (a_verb, "PUT") == 0 || strcmp (a_verb, "PATCH") == 0) {
            curl_easy_setopt (l_curl, CURLOPT_POSTFIELDS, l_has_body ? a_body : "");
            curl_easy_setopt (l_curl, CURLOPT_POSTFIELDSIZE, l_has_body ? (long) a_body_len : 0L);
        }
        curl_easy_setopt (l_curl, CURLOPT_CUSTOMREQUEST, a_verb);
    }

    l_code = curl_easy_perform (l_curl);
    if (l_code != CURLE_OK) {
        l_error = swhttp_error_code (l_code);
        goto cleanup;
    }
    curl_easy_getinfo (l_curl, CURLINFO_RESPONSE_CODE, &l_status);
    if (a_out_status != NULL) *a_out_status = (int) l_status;
    if (a_out_len != NULL) *a_out_len = (int) l_body.count;
    if (a_out_headers != NULL) {
        *a_out_headers = l_headers.data;
    } else {
        free (l_headers.data);
    }
    curl_slist_free_all (l_list);
    curl_easy_cleanup (l_curl);
    free (l_url);
    return l_body.data;

cleanup:
    if (a_out_winerr != NULL)   *a_out_winerr = l_body.overflowed ? 0 : l_error;
    if (a_out_overflow != NULL) *a_out_overflow = l_body.overflowed;
    free (l_body.data);
    free (l_headers.data);
    if (l_list != NULL) curl_slist_free_all (l_list);
    if (l_curl != NULL) curl_easy_cleanup (l_curl);
    free (l_url);
    return NULL;
}

static void swhttp_free (char *p) { if (p) free (p); }
#endif

#endif /* SIMPLE_WINHTTP_H */
