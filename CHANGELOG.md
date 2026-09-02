# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-09-02

### Fixed
- **Every external that waits on the network is now marked `blocking`.**
  `SIMPLE_WINHTTP.c_send` - the one call that performs a whole HTTP exchange -
  was declared `external "C inline use "simple_winhttp.h""` with no `blocking`
  marker. ISE's garbage collector stops every thread of the system before it
  collects, and a thread inside an unmarked external is where the runtime can
  neither see it nor stop it: the collection waits for that call to return, and
  every other processor waits with it, at its very next allocation. A library
  whose whole purpose is to wait on a peer therefore stopped the entire program
  for the length of every request.

  HOW IT WAS FOUND. Larry's simple_chat window froze on 2026-09-02: 13 stalls
  and 211 seconds of frozen window in one 20-minute session, each stall just
  under the client's 25 s long-poll timeout. Windows ghosts a window that stops
  pumping for about five seconds and throws the keystrokes at it away, so the
  stalls cost input, not just time - messages arrived truncated, doubled and out
  of order. Instrumenting simple_chat cleared its own wiring completely (no call
  it made on another processor ever took longer than 3 ms) and put the stall in
  the root processor's ALLOCATOR: 21,060 ms for a plain 200 x 1 KiB allocation
  burst while the poller held one exchange open here.

  MEASURED, on the same machine, same duration, nothing else running: a
  processor asleep 9,000 ms in `EXECUTION_ENVIRONMENT.sleep` (which EiffelBase
  itself marks `C blocking`) cost another processor's worst allocation 1 ms; a
  processor inside a 3,000 ms UNMARKED C call cost it 7,931 ms.

  The fix is one keyword: `external "C blocking inline use "simple_winhttp.h""`.
  It is safe here because nothing the C layer touches is Eiffel-collected memory
  - every buffer crossing the boundary is a `C_STRING` / `MANAGED_POINTER` on the
  C heap, and the out parameters are addresses of the calling routine's own
  basic-typed locals.

  `c_free` is deliberately left unmarked: it is one `free ()` on a buffer this
  process already owns, and cannot wait on anything.

### Added
- `simple_winhttp_scoop_tests` - a SCOOP test target carrying the vector test
  that would have caught this. `SLOW_HTTP_LISTENER` is a raw loopback listener
  (EiffelNet, whose every socket external ISE already marks `C blocking`) that
  holds each answer back 3 s; `WINHTTP_CALLER` drives the real `SIMPLE_WINHTTP`
  from its own processor; the root does nothing but allocate and records its
  worst single allocation. `BLOCKING_PROBE` holds the law itself - the same wait
  taken three ways (an Eiffel sleep, an unmarked C call, the same C call marked
  `blocking`).

  RED (0.1.0, `c_send` unmarked): worst allocation on the root **15,801 ms**,
  and the exchanges never completed at all - the in-process listener was frozen
  by the same rendezvous and could not answer inside its 15 s timeout, so the
  transport reported 32,017 ms for two 3 s exchanges. 3 passed, 1 failed.
  GREEN (0.1.1): the two 3 s exchanges take **6,018 ms** in the transport and the
  root's worst allocation is **3 ms**. 4 passed, 0 failed. The assertion is
  bounded at 500 ms, with margin on both sides.

  VERIFIED AT THE CONSUMER. simple_chat's own live GUI assault - the finalized
  server on loopback, the real client stack, 20 posts and then 140 heartbeats
  through one whole quiet 25 s long poll - with its `EVENT_POLLER
  .Poll_slice_seconds` put back to the full `{CHAT_CLIENT}.Max_wait_seconds`:
  worst allocation burst **21,301 ms against 0.1.0** and **1 ms against 0.1.1**.
  Its suite is 188 passed / 0 failed either way.

### Changed
- `SIMPLE_WINHTTP`'s class note and the README now state the guarantee: an
  exchange in flight never stops another processor's allocator.

[0.1.1]: https://github.com/simple-eiffel/simple_winhttp/releases/tag/v0.1.1

## [0.1.0] - 2026-09-01

### Added
- `SIMPLE_WINHTTP` facade: `get` / `post` / `send` - one synchronous exchange per
  call; every network condition (refused, timeout, TLS failure, oversized body)
  comes back as a `SIMPLE_WINHTTP_RESPONSE` result, never an exception.
- `SIMPLE_WINHTTP_RESPONSE`: status, raw body bytes, raw response headers with
  case-insensitive `header` lookup, `location`, `is_exchanged` / `is_success` /
  `is_redirect`, transport `error` text.
- Redirects are NEVER followed: `WINHTTP_OPTION_REDIRECT_POLICY_NEVER` is set on
  the session before any request (the exchange is abandoned if it cannot be), so
  a 3xx is the reply and an Authorization header is never re-sent to a host the
  server names. No off switch.
- HTTPS through SChannel (`WINHTTP_FLAG_SECURE`); certificate validation ON by
  default with `set_certificate_validation (False)` for lab rigs.
- Bounded response bodies: `body_maximum` (default 16 MiB), enforced in the read
  loop before allocation grows.
- Separate connect (10 s) and receive (40 s) timeout defaults; per-call receive
  timeout on `send` for long-poll callers.
- ASCII boundary checks on URLs and headers (header injection dies at the
  precondition); bodies are bytes both ways, marshalled byte-for-byte.
- C layer (`Clib/simple_winhttp.h`) promoted from simple_ocr_capture's proven
  `ocr_http.h`: WinHTTP prototypes declared locally (SDK-independent under the
  Eiffel C build's `-D_WIN32_WINNT=0x0500`), `#pragma comment(lib, "winhttp.lib")`,
  single-cleanup-exit handle discipline, chunk-looped body reads; extended with
  TLS, headers, redirect policy, raw response headers, body cap, and out-parameter
  state (no globals - SCOOP-safe).
- Test suite: 15 offline unit tests (URL cracking, header assembly, guards,
  response parsing, connection-refused-as-a-result) + 4 live local tests
  (simple_chat /health, /login, 404; a real 302 never followed) that SKIP when
  their localhost helper is down. No internet, ever.

[0.1.0]: https://github.com/simple-eiffel/simple_winhttp/releases/tag/v0.1.0
