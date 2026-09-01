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
/* ============ NON-WINDOWS STUBS ============ */
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
    (void) a_verb; (void) a_host; (void) a_port; (void) a_path;
    (void) a_use_tls; (void) a_headers; (void) a_body; (void) a_body_len;
    (void) a_connect_ms; (void) a_receive_ms; (void) a_max_body;
    (void) a_validate_certs;
    if (a_out_len)      *a_out_len = 0;
    if (a_out_headers)  *a_out_headers = 0;
    if (a_out_status)   *a_out_status = 0;
    if (a_out_winerr)   *a_out_winerr = 0;
    if (a_out_overflow) *a_out_overflow = 0;
    return 0;
}
static void swhttp_free (char *p) { (void) p; }
#endif

#endif /* SIMPLE_WINHTTP_H */
