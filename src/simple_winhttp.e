note
	description: "[
		Windows-native HTTPS client: one synchronous exchange per call,
		riding WinHTTP (in every supported Windows - nothing to
		redistribute, unlike libcurl). Promoted from simple_ocr_capture's
		proven OCR_HTTP and extended with HTTPS, request headers, a
		per-call receive timeout and a bounded response body.

		THE CONTRACT A CALLER LEANS ON:

		* A network condition is a RESULT, never an exception:
		  `send' / `get' / `post' always answer with a
		  SIMPLE_WINHTTP_RESPONSE; when nothing was exchanged it carries
		  `error' text and `is_exchanged' False.

		* Redirects are NEVER followed (`Redirects_are_never_followed'):
		  the session is switched to WINHTTP_OPTION_REDIRECT_POLICY_NEVER
		  before any request, so a 3xx IS the reply - its Location header
		  is surfaced, and an Authorization header is never re-sent to a
		  host the server names. There is deliberately no way to turn
		  this off.

		* The response body is bounded by `body_maximum' (default 16 MiB);
		  beyond it the exchange fails cleanly instead of growing without
		  bound.

		* HTTPS certificate validation is ON by default;
		  `set_certificate_validation (False)' exists for lab rigs with
		  self-signed certificates and is never the default posture.

		* UTF-8 discipline: URLs and header names/values are ASCII
		  (checked at this boundary); bodies are BYTES (STRING_8) in both
		  directions - UTF-8 JSON travels as its bytes.

		* A WAIT HERE IS NEVER THE WHOLE PROGRAM'S WAIT (0.1.1): the one
		  external that waits on the network, `c_send', is marked
		  `blocking', so ISE's garbage collector may run - and every
		  other processor may keep allocating - while an exchange is in
		  flight. Without that marker a 25 s long poll stops every other
		  processor for 25 s at its next allocation.

		SCOOP: one instance per processor. An instance keeps no handles
		between calls (the whole Win32 handle lifecycle lives inside one
		C call and closes on every path), and the C layer keeps no global
		state, so instances on different processors never interfere.

		Timeouts: `connect_timeout_seconds' governs resolve + connect;
		the receive timeout is per call (`send') or `receive_timeout_seconds'
		(`get' / `post'). The default receive timeout (40 s) comfortably
		exceeds a 25-30 s long-poll hold.
	]"
	author: "Larry Rix"

class
	SIMPLE_WINHTTP

create
	make

feature {NONE} -- Initialization

	make
			-- A client with the safe defaults: 10 s connect, 40 s receive,
			-- 16 MiB body ceiling, certificate validation on.
		do
			connect_timeout_seconds := 10
			receive_timeout_seconds := 40
			body_maximum := Default_body_maximum
			is_certificate_validation_enabled := True
			create parsed_host.make_empty
			create parsed_path.make_from_string ("/")
		ensure
			connect_default: connect_timeout_seconds = 10
			receive_covers_long_poll: receive_timeout_seconds = 40
			bounded_default: body_maximum = Default_body_maximum
			validating: is_certificate_validation_enabled
			nothing_sent: exchange_count = 0
		end

feature -- Access

	connect_timeout_seconds: INTEGER
			-- Resolve + connect allowance for every exchange.

	receive_timeout_seconds: INTEGER
			-- Receive allowance used by `get' and `post'; `send' takes
			-- its own per-call value.

	body_maximum: INTEGER
			-- Hard cap on a response body, bytes.

	exchange_count: INTEGER
			-- Exchanges attempted so far by this instance.

feature -- Status report

	is_certificate_validation_enabled: BOOLEAN
			-- Are HTTPS certificates fully validated? (Default: True.)

	Redirects_are_never_followed: BOOLEAN = True
			-- The transport's standing guarantee: a 3xx is returned to the
			-- caller (WINHTTP_OPTION_REDIRECT_POLICY_NEVER on the session);
			-- no Location is ever transparently followed, so nothing -
			-- bearer headers included - is ever re-sent by this library.

feature -- Element change

	set_connect_timeout_seconds (a_seconds: INTEGER)
			-- Allow `a_seconds' for resolve + connect.
		require
			positive: a_seconds > 0
		do
			connect_timeout_seconds := a_seconds
		ensure
			set: connect_timeout_seconds = a_seconds
		end

	set_receive_timeout_seconds (a_seconds: INTEGER)
			-- Allow `a_seconds' for send + receive on `get' / `post'.
			-- For a long-poll that holds 25-30 s, set this comfortably
			-- above the hold (the default 40 already is).
		require
			positive: a_seconds > 0
		do
			receive_timeout_seconds := a_seconds
		ensure
			set: receive_timeout_seconds = a_seconds
		end

	set_body_maximum (a_bytes: INTEGER)
			-- Accept response bodies up to `a_bytes' (at most 1 GiB: the C
			-- layer's cap arithmetic stays comfortably inside 32 bits).
		require
			positive: a_bytes > 0
			sane: a_bytes <= 1_073_741_824
		do
			body_maximum := a_bytes
		ensure
			set: body_maximum = a_bytes
		end

	set_certificate_validation (a_enabled: BOOLEAN)
			-- Validate HTTPS certificates when `a_enabled' (the default
			-- posture); False is for lab rigs with self-signed
			-- certificates, never for production.
		do
			is_certificate_validation_enabled := a_enabled
		ensure
			set: is_certificate_validation_enabled = a_enabled
		end

feature -- Basic operations

	get (a_url: READABLE_STRING_8): SIMPLE_WINHTTP_RESPONSE
			-- One GET of `a_url' with no extra headers, waiting up to
			-- `receive_timeout_seconds'. Failures are results.
		require
			web_url: is_web_url (a_url)
			ascii_url: is_ascii_url (a_url)
		local
			l_headers: HASH_TABLE [STRING_8, STRING_8]
		do
			create l_headers.make (0)
			Result := send ("GET", a_url, l_headers, Void, receive_timeout_seconds)
		ensure
			attempted: exchange_count = old exchange_count + 1
			bounded: Result.body.count <= body_maximum
		end

	post (a_url: READABLE_STRING_8; a_body: READABLE_STRING_8): SIMPLE_WINHTTP_RESPONSE
			-- One POST of `a_body' (bytes, sent verbatim) to `a_url' with
			-- no extra headers, waiting up to `receive_timeout_seconds'.
			-- A caller who owes the server a Content-Type uses `send'.
		require
			web_url: is_web_url (a_url)
			ascii_url: is_ascii_url (a_url)
		local
			l_headers: HASH_TABLE [STRING_8, STRING_8]
		do
			create l_headers.make (0)
			Result := send ("POST", a_url, l_headers, a_body, receive_timeout_seconds)
		ensure
			attempted: exchange_count = old exchange_count + 1
			bounded: Result.body.count <= body_maximum
		end

	send (a_method, a_url: READABLE_STRING_8; a_headers: HASH_TABLE [STRING_8, STRING_8];
			a_body: detachable READABLE_STRING_8; a_timeout_seconds: INTEGER): SIMPLE_WINHTTP_RESPONSE
			-- One exchange: `a_method' on `a_url' with `a_headers' and the
			-- optional `a_body' bytes, waiting up to `a_timeout_seconds'
			-- for the answer. Never raises for a network condition; a 3xx
			-- is the reply and is never followed; a body beyond
			-- `body_maximum' is a transport failure, never a memory bomb.
		require
			known_method: is_known_method (a_method)
			web_url: is_web_url (a_url)
			ascii_url: is_ascii_url (a_url)
			clean_headers: is_header_table_clean (a_headers)
			positive_timeout: a_timeout_seconds > 0
		local
			l_c_verb, l_c_host, l_c_path, l_c_headers: C_STRING
			l_body_area: detachable MANAGED_POINTER
			l_body_ptr, l_reply_ptr, l_headers_ptr: POINTER
			l_body_len, l_len, l_status, l_winerr, l_overflow, i: INTEGER
			l_raw_headers: STRING_8
			l_error: STRING_32
		do
			exchange_count := exchange_count + 1
			if not parse_url (a_url) then
				l_error := {STRING_32} "Not a usable http(s) URL: "
				l_error.append_string_general (a_url)
				create Result.make_failed (l_error)
			else
				create l_c_verb.make (a_method)
				create l_c_host.make (parsed_host)
				create l_c_path.make (parsed_path)
				create l_c_headers.make (header_block (a_headers))

					-- The body is marshalled byte-for-byte: C_STRING would
					-- re-encode characters 128..255 as multi-byte UTF-8 and
					-- corrupt bodies that are already UTF-8 bytes.
				if attached a_body as la_body and then not la_body.is_empty then
					l_body_len := la_body.count
					create l_body_area.make (l_body_len)
					from
						i := 1
					until
						i > l_body_len
					loop
						l_body_area.put_natural_8 (la_body.code (i).to_natural_8, i - 1)
						i := i + 1
					end
					l_body_ptr := l_body_area.item
				end

				l_reply_ptr := c_send (l_c_verb.item, l_c_host.item, parsed_port, l_c_path.item,
					bool_to_int (parsed_is_tls), l_c_headers.item,
					l_body_ptr, l_body_len,
					connect_timeout_seconds * 1000, a_timeout_seconds * 1000,
					body_maximum, bool_to_int (is_certificate_validation_enabled),
					$l_len, $l_headers_ptr, $l_status, $l_winerr, $l_overflow)

				if l_reply_ptr = default_pointer then
					if l_overflow = 1 then
						l_error := {STRING_32} "Response body exceeds body_maximum ("
						l_error.append_string_general (body_maximum.out)
						l_error.append_string_general (" bytes allowed)")
					else
						l_error := failure_description (a_method, a_url, l_winerr)
					end
					create Result.make_failed (l_error)
				else
					if l_headers_ptr /= default_pointer then
						l_raw_headers := copied_text (l_headers_ptr)
						c_free (l_headers_ptr)
					else
						create l_raw_headers.make_empty
					end
					if l_status >= 100 and l_status <= 599 then
						create Result.make (l_status, copied_bytes (l_reply_ptr, l_len), l_raw_headers)
					else
							-- WinHTTP answered but no usable status arrived: a
							-- malformed peer. Still a result, never an exception.
						l_error := {STRING_32} "No usable HTTP status in the answer from "
						l_error.append_string_general (a_url)
						create Result.make_failed (l_error)
					end
					c_free (l_reply_ptr)
				end
			end
		ensure
			attempted: exchange_count = old exchange_count + 1
			bounded: Result.body.count <= body_maximum
			failure_is_explained: not Result.is_exchanged implies not Result.error.is_empty
			redirects_surface: Result.is_redirect implies Redirects_are_never_followed
		end

feature -- Validation (contract support)

	is_known_method (a_method: READABLE_STRING_8): BOOLEAN
			-- Is `a_method' one this client sends?
		do
			Result := a_method.same_string ("GET") or a_method.same_string ("POST")
				or a_method.same_string ("PUT") or a_method.same_string ("DELETE")
				or a_method.same_string ("PATCH") or a_method.same_string ("HEAD")
				or a_method.same_string ("OPTIONS")
		end

	is_web_url (a_url: READABLE_STRING_8): BOOLEAN
			-- Does `a_url' name an http or https resource?
		do
			Result := a_url.starts_with ("http://") or a_url.starts_with ("https://")
		end

	is_ascii_url (a_url: READABLE_STRING_8): BOOLEAN
			-- Printable ASCII with no blanks - what goes on the wire
			-- verbatim. (Encode anything else before it reaches this
			-- boundary.)
		do
			Result := not a_url.is_empty
			across
				a_url as ic
			loop
				Result := Result and ic.code >= 33 and ic.code <= 126
			end
		end

	is_header_table_clean (a_headers: HASH_TABLE [STRING_8, STRING_8]): BOOLEAN
			-- Every name printable ASCII without ':' or blanks; every
			-- value printable ASCII (blanks allowed). CR and LF cannot
			-- pass, so header injection cannot either.
		do
			Result := True
			across
				a_headers as ic
			loop
				Result := Result and is_clean_header_name (@ic.key) and is_clean_header_value (ic)
			end
		end

	is_clean_header_name (a_name: READABLE_STRING_8): BOOLEAN
			-- 1+ characters of printable ASCII, no ':' and no blanks.
		do
			Result := not a_name.is_empty
			across
				a_name as ic
			loop
				Result := Result and ic.code >= 33 and ic.code <= 126 and ic /= ':'
			end
		end

	is_clean_header_value (a_value: READABLE_STRING_8): BOOLEAN
			-- Printable ASCII, blanks allowed, never CR or LF.
		do
			Result := True
			across
				a_value as ic
			loop
				Result := Result and ic.code >= 32 and ic.code <= 126
			end
		end

feature -- URL cracking

	parse_url (a_url: READABLE_STRING_8): BOOLEAN
			-- Split `a_url' into `parsed_host', `parsed_port',
			-- `parsed_path' (query included) and `parsed_is_tls'.
			-- http:// defaults to port 80, https:// to 443.
		local
			l_url, l_rest, l_authority, l_port_text: STRING_8
			l_slash, l_colon, l_default_port: INTEGER
		do
				-- Copy once into a STRING_8 so every substring below is
				-- already a STRING_8 (no obsolete conversions).
			create l_url.make_from_string (a_url)
			l_default_port := 0
			create l_rest.make_empty
			if l_url.count > 7 and then l_url.substring (1, 7).is_case_insensitive_equal ("http://") then
				l_rest := l_url.substring (8, l_url.count)
				parsed_is_tls := False
				l_default_port := 80
			elseif l_url.count > 8 and then l_url.substring (1, 8).is_case_insensitive_equal ("https://") then
				l_rest := l_url.substring (9, l_url.count)
				parsed_is_tls := True
				l_default_port := 443
			end
			if l_default_port > 0 then
				l_slash := l_rest.index_of ('/', 1)
				if l_slash = 0 then
					l_authority := l_rest
					create parsed_path.make_from_string ("/")
				else
					l_authority := l_rest.substring (1, l_slash - 1)
					parsed_path := l_rest.substring (l_slash, l_rest.count)
				end
				l_colon := l_authority.index_of (':', 1)
				if l_colon = 0 then
					parsed_host := l_authority
					parsed_port := l_default_port
				else
					parsed_host := l_authority.substring (1, l_colon - 1)
					l_port_text := l_authority.substring (l_colon + 1, l_authority.count)
					if l_port_text.is_integer then
						parsed_port := l_port_text.to_integer
					else
						parsed_port := 0
					end
				end
				Result := not parsed_host.is_empty and parsed_port >= 1 and parsed_port <= 65535
			end
		ensure
			host_on_success: Result implies not parsed_host.is_empty
			port_on_success: Result implies (parsed_port >= 1 and parsed_port <= 65535)
			path_rooted: Result implies parsed_path.starts_with ("/")
		end

	parsed_host: STRING_8
			-- Host from the most recent `parse_url'.

	parsed_path: STRING_8
			-- Path with query, leading slash, from the most recent `parse_url'.

	parsed_port: INTEGER
			-- Port from the most recent `parse_url'.

	parsed_is_tls: BOOLEAN
			-- Was the most recent `parse_url' an https:// URL?

feature -- Header assembly

	header_block (a_headers: HASH_TABLE [STRING_8, STRING_8]): STRING_8
			-- `a_headers' as one wire-ready block: "Name: value" lines,
			-- CRLF-terminated; empty for an empty table.
		require
			clean: is_header_table_clean (a_headers)
		do
			create Result.make (a_headers.count * 32)
			across
				a_headers as ic
			loop
				Result.append (@ic.key)
				Result.append (": ")
				Result.append (ic)
				Result.append ("%R%N")
			end
		ensure
			empty_for_empty: a_headers.is_empty implies Result.is_empty
			terminated: (not a_headers.is_empty) implies Result.ends_with ("%R%N")
		end

feature -- Constants

	Default_body_maximum: INTEGER = 16_777_216
			-- 16 MiB: the ecosystem's transport ceiling (simple_chat's
			-- HTTP_TRANSPORT.Body_maximum).

feature {NONE} -- Implementation

	failure_description (a_method, a_url: READABLE_STRING_8; a_winerr: INTEGER): STRING_32
			-- Human-readable reason `a_method' on `a_url' exchanged nothing.
		require
			method_given: not a_method.is_empty
			url_given: not a_url.is_empty
		do
			Result := {STRING_32} "WinHTTP "
			Result.append_string_general (a_method)
			Result.append_string_general (" ")
			Result.append_string_general (a_url)
			Result.append_string_general (" failed: ")
			inspect a_winerr
			when 12002 then
				Result.append_string_general ("timed out")
			when 12007 then
				Result.append_string_general ("name not resolved")
			when 12029 then
				Result.append_string_general ("cannot connect")
			when 12030 then
				Result.append_string_general ("connection ended prematurely")
			when 12175 then
				Result.append_string_general ("TLS/certificate failure")
			else
				Result.append_string_general ("transport error")
			end
			Result.append_string_general (" (Win32 ")
			Result.append_string_general (a_winerr.out)
			Result.append_string_general (")")
		ensure
			explained: not Result.is_empty
		end

	copied_bytes (a_ptr: POINTER; a_count: INTEGER): STRING_8
			-- The `a_count' bytes at `a_ptr', byte-for-byte - NUL bytes
			-- included, so binary bodies survive.
		require
			exists: a_ptr /= default_pointer
			non_negative: a_count >= 0
		local
			l_area: MANAGED_POINTER
			i: INTEGER
		do
			create Result.make (a_count)
			if a_count > 0 then
				create l_area.share_from_pointer (a_ptr, a_count)
				from
					i := 0
				until
					i >= a_count
				loop
					Result.extend (l_area.read_natural_8 (i).to_character_8)
					i := i + 1
				end
			end
		ensure
			sized: Result.count = a_count
		end

	copied_text (a_ptr: POINTER): STRING_8
			-- The NUL-terminated text at `a_ptr' (response headers - text
			-- by construction).
		require
			exists: a_ptr /= default_pointer
		local
			l_c: C_STRING
		do
			create l_c.make_by_pointer (a_ptr)
			Result := l_c.substring (1, l_c.count)
		end

	bool_to_int (a_value: BOOLEAN): INTEGER
			-- 1 for True, 0 for False - across the C boundary.
		do
			if a_value then
				Result := 1
			end
		ensure
			definition: Result = 1 or Result = 0
			true_is_one: a_value = (Result = 1)
		end

feature {NONE} -- Externals

	c_send (a_verb, a_host: POINTER; a_port: INTEGER; a_path: POINTER; a_tls: INTEGER;
			a_headers, a_body: POINTER; a_body_len, a_connect_ms, a_receive_ms, a_max_body, a_validate: INTEGER;
			a_out_len: TYPED_POINTER [INTEGER]; a_out_headers: TYPED_POINTER [POINTER];
			a_out_status, a_out_winerr, a_out_overflow: TYPED_POINTER [INTEGER]): POINTER
			-- One exchange in C; NULL when nothing was exchanged. See
			-- swhttp_request in Clib/simple_winhttp.h.
			--
			-- MARKED `blocking' (0.1.1), and it must stay marked. This call
			-- WAITS - on a DNS answer, on a TCP handshake, on a TLS
			-- handshake, and above all on a peer that may hold the answer
			-- back for as long as `a_receive_ms' allows. ISE's garbage
			-- collector stops every thread of the system before it collects,
			-- and a thread inside an UNMARKED external is where the runtime
			-- can neither see it nor stop it: the collection waits for the
			-- call to return, and every other processor waits with it, at
			-- its very next allocation. Unmarked, one 25 s long poll here
			-- froze simple_chat's window for 25 s (2026-09-02). The marker
			-- tells the runtime this thread has left Eiffel, so a collection
			-- may proceed without it.
			--
			-- Marking is SAFE here because nothing the C layer touches is
			-- Eiffel-collected memory: every buffer crossing the boundary is
			-- C_STRING / MANAGED_POINTER (C heap), and the out parameters
			-- are addresses of this routine's own basic-typed locals.
		external
			"C blocking inline use %"simple_winhttp.h%""
		alias
			"return swhttp_request ((const char *) $a_verb, (const char *) $a_host, (int) $a_port, (const char *) $a_path, (int) $a_tls, (const char *) $a_headers, (const char *) $a_body, (int) $a_body_len, (int) $a_connect_ms, (int) $a_receive_ms, (int) $a_max_body, (int) $a_validate, (int *) $a_out_len, (char **) $a_out_headers, (int *) $a_out_status, (int *) $a_out_winerr, (int *) $a_out_overflow);"
		end

	c_free (a_ptr: POINTER)
			-- Release a buffer the C layer handed over.
			--
			-- Deliberately NOT `blocking': this is one `free ()' on a buffer
			-- this process already owns. It cannot wait on a network, a
			-- disk or a lock the runtime cares about, and marking a call
			-- this short would cost two runtime transitions to save nothing.
		external
			"C inline use %"simple_winhttp.h%""
		alias
			"swhttp_free ((char *) $a_ptr);"
		end

invariant
	positive_connect_timeout: connect_timeout_seconds > 0
	positive_receive_timeout: receive_timeout_seconds > 0
	positive_body_maximum: body_maximum > 0
	non_negative_exchanges: exchange_count >= 0
	host_attached: parsed_host /= Void
	path_attached: parsed_path /= Void

end
