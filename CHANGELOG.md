# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
