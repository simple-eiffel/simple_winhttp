<p align="center">
  <img src="docs/images/logo.svg" alt="simple_winhttp logo" width="400">
</p>

# simple_winhttp

**[Documentation](https://simple-eiffel.github.io/simple_winhttp/)** | **[GitHub](https://github.com/simple-eiffel/simple_winhttp)**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Eiffel](https://img.shields.io/badge/Eiffel-25.02-blue.svg)](https://www.eiffel.org/)
[![Design by Contract](https://img.shields.io/badge/DbC-enforced-orange.svg)]()

Windows-native HTTP/HTTPS client on WinHTTP: one synchronous exchange per call, failures as results, redirects never followed.

Part of the [Simple Eiffel](https://github.com/simple-eiffel) ecosystem.

## Why

`simple_http` rides libcurl, and libcurl.dll ships only inside an EiffelStudio installation - a finalized binary on a customer's machine cannot resolve it. WinHTTP is part of every supported Windows: nothing to redistribute, HTTPS through SChannel, and the system certificate store for free. The WinHTTP glue was proven in the field inside `simple_ocr_capture` (OCR_HTTP) and is promoted here as a library, extended with HTTPS, request headers, per-call timeouts and a bounded body.

## The contract a caller leans on

- **A network condition is a result, never an exception.** Every call answers with a `SIMPLE_WINHTTP_RESPONSE`; when nothing was exchanged it carries `error` text and `is_exchanged` is False.
- **Redirects are never followed.** The session is switched to `WINHTTP_OPTION_REDIRECT_POLICY_NEVER` before any request, so a 3xx IS the reply - its `Location` is surfaced, and an `Authorization` header is never re-sent to a host the server names. There is deliberately no way to turn this off.
- **Bodies are bounded** by `body_maximum` (default 16 MiB); beyond it the exchange fails cleanly.
- **HTTPS certificate validation is ON by default**; `set_certificate_validation (False)` exists for lab rigs with self-signed certificates.
- **UTF-8 discipline**: URLs and header names/values are ASCII (checked at the boundary); bodies are bytes (`STRING_8`) in both directions.
- **A request in flight never stalls the rest of the program.** Every external here that waits on the network is marked `blocking`, so ISE's garbage collector may run - and every other processor may keep allocating - while an exchange is open. An unmarked waiting external would stop every thread of the system for the whole request: see CHANGELOG 0.1.1.

## Installation

Set the ecosystem environment variable (one-time setup for all simple_* libraries):
```
SIMPLE_EIFFEL=D:\prod
```

Add to your ECF:
```xml
<library name="simple_winhttp" location="$SIMPLE_EIFFEL/simple_winhttp/simple_winhttp.ecf"/>
```

No external_library entry is needed: the C layer links winhttp.lib via `#pragma comment`.

## Usage

```eiffel
local
    client: SIMPLE_WINHTTP
    headers: HASH_TABLE [STRING_8, STRING_8]
    response: SIMPLE_WINHTTP_RESPONSE
do
    create client.make

    -- One GET
    response := client.get ("https://127.0.0.1:8443/health")
    if response.is_success then
        print (response.body)
    elseif response.is_exchanged then
        print ("HTTP " + response.status.out)
    else
        print (response.error)    -- refused, timed out, TLS failure, ...
    end

    -- One POST with headers and a per-call timeout (long-poll friendly)
    create headers.make (2)
    headers.put ("application/json", "Content-Type")
    headers.put ("Bearer " + token, "Authorization")
    response := client.send ("POST", url, headers, "{%"body%": %"hi%"}", 40)

    -- A 3xx is the reply, never followed
    if response.is_redirect and then attached response.location as where then
        print ("Server points at " + where + " - the caller decides.%N")
    end
end
```

### Options

| Feature | Default | Meaning |
|---|---|---|
| `set_connect_timeout_seconds` | 10 | resolve + connect allowance |
| `set_receive_timeout_seconds` | 40 | receive allowance for `get`/`post` (comfortably above a 25-30 s long-poll; `send` takes a per-call value) |
| `set_body_maximum` | 16 MiB | hard cap on a response body |
| `set_certificate_validation` | True | full HTTPS certificate validation |

## SCOOP

One instance per processor. An instance keeps no Win32 handles between calls (the whole handle lifecycle lives inside one C call and closes on every path), and the C layer keeps no global state - status, error and overflow travel through out parameters - so instances on different processors never interfere.

**And an exchange never freezes the others.** `c_send` is declared `external "C blocking inline ..."`. ISE's collector stops every thread of the system before it collects, and a thread inside an *unmarked* external cannot be seen or stopped, so the collection waits for it - and every other processor waits with it, at its very next allocation. Marked, the runtime knows the thread has left Eiffel and collects without it. That is why a 25 s long poll through this library costs the GUI processor nothing; unmarked, it cost it 25 s (simple_chat, 2026-09-02). `c_free` is left unmarked on purpose: one `free ()` cannot wait on anything.

## Tests

```
/d/prod/ec.sh test -config simple_winhttp.ecf -target simple_winhttp_tests
./EIFGENs/simple_winhttp_tests/F_code/simple_winhttp.exe
```

No internet is ever touched. The unit tests cover the pure parts plus connection-refused-as-a-result against a dead local port. The live tests speak to two optional localhost helpers (a simple_chat server on 8130, a 302-answering helper on 8132) and print SKIP when a helper is not up, so the suite stays green on a bare machine.

### The freeze assault (SCOOP)

```
/d/prod/ec.sh test -config simple_winhttp.ecf -target simple_winhttp_scoop_tests
./EIFGENs/simple_winhttp_scoop_tests/F_code/simple_winhttp.exe
```

Four tests on two processors, no internet and no helper. A raw loopback listener holds each answer back three seconds while a second processor drives the real `SIMPLE_WINHTTP` and the root does nothing but allocate; the root's worst single allocation must stay under 500 ms. Unmarked it was 15,801 ms; marked it is single-digit. Three companion probes hold the law itself - the same wait as an Eiffel sleep, as an unmarked C call, and as the same C call marked `blocking`.

## License

MIT License
