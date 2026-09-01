note
	description: "[
		Tests for SIMPLE_WINHTTP that need no internet and no running
		server: the pure parts (URL cracking, header assembly, response
		parsing, the guard predicates) plus the one network condition a
		bare machine can always produce - connection refused against a
		dead local port, which must come back as a RESULT, never an
		exception.
	]"
	author: "Larry Rix"
	testing: "covers"

class
	LIB_TESTS

inherit
	TEST_SET_BASE

feature -- Test: defaults and options

	test_defaults
			-- The safe posture out of the box.
		note
			testing: "covers/{SIMPLE_WINHTTP}.make"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_integers_equal ("connect 10 s", 10, l_client.connect_timeout_seconds)
			assert_integers_equal ("receive 40 s covers a 25-30 s long-poll", 40, l_client.receive_timeout_seconds)
			assert_integers_equal ("16 MiB ceiling", 16777216, l_client.body_maximum)
			assert_true ("certificates validated", l_client.is_certificate_validation_enabled)
			assert_integers_equal ("nothing sent", 0, l_client.exchange_count)
		end

	test_options_settable
			-- Timeouts, ceiling and validation are the caller's to set.
		note
			testing: "covers/{SIMPLE_WINHTTP}.set_receive_timeout_seconds"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			l_client.set_connect_timeout_seconds (5)
			l_client.set_receive_timeout_seconds (60)
			l_client.set_body_maximum (1024)
			l_client.set_certificate_validation (False)
			assert_integers_equal ("connect", 5, l_client.connect_timeout_seconds)
			assert_integers_equal ("receive", 60, l_client.receive_timeout_seconds)
			assert_integers_equal ("ceiling", 1024, l_client.body_maximum)
			assert_false ("validation off for the lab rig", l_client.is_certificate_validation_enabled)
		end

	test_redirect_policy_is_never
			-- The seam for the no-redirect guarantee: the constant is
			-- wired True, with no setter anywhere in the class. The C
			-- layer sets WINHTTP_OPTION_REDIRECT_POLICY_NEVER on every
			-- session and abandons the exchange if it cannot; the live
			-- proof against a real 3xx runs in LIVE_TESTS when the local
			-- redirect helper is up.
		note
			testing: "covers/{SIMPLE_WINHTTP}.Redirects_are_never_followed"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("never followed", l_client.Redirects_are_never_followed)
		end

feature -- Test: URL cracking

	test_parse_http_url
		note
			testing: "covers/{SIMPLE_WINHTTP}.parse_url"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("parses", l_client.parse_url ("http://example.org"))
			assert_strings_equal ("host", "example.org", l_client.parsed_host)
			assert_integers_equal ("port 80", 80, l_client.parsed_port)
			assert_strings_equal ("root path", "/", l_client.parsed_path)
			assert_false ("plain http", l_client.parsed_is_tls)
		end

	test_parse_https_url
		note
			testing: "covers/{SIMPLE_WINHTTP}.parse_url"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("parses", l_client.parse_url ("https://example.org/inbox"))
			assert_strings_equal ("host", "example.org", l_client.parsed_host)
			assert_integers_equal ("port 443", 443, l_client.parsed_port)
			assert_strings_equal ("path", "/inbox", l_client.parsed_path)
			assert_true ("tls", l_client.parsed_is_tls)
		end

	test_parse_url_port_and_query
			-- The long-poll shape: explicit port, path and query travel whole.
		note
			testing: "covers/{SIMPLE_WINHTTP}.parse_url"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("parses", l_client.parse_url ("http://127.0.0.1:8130/rooms/1/wait?since=42"))
			assert_strings_equal ("host", "127.0.0.1", l_client.parsed_host)
			assert_integers_equal ("port", 8130, l_client.parsed_port)
			assert_strings_equal ("path keeps the query", "/rooms/1/wait?since=42", l_client.parsed_path)
			assert_false ("plain http", l_client.parsed_is_tls)
		end

	test_parse_url_rejections
			-- Whatever cannot go on the wire is refused, not guessed at.
		note
			testing: "covers/{SIMPLE_WINHTTP}.parse_url"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_false ("ftp scheme", l_client.parse_url ("ftp://example.org/file"))
			assert_false ("no scheme", l_client.parse_url ("example.org/path"))
			assert_false ("empty host", l_client.parse_url ("http:///path"))
			assert_false ("garbage port", l_client.parse_url ("http://example.org:notaport/x"))
			assert_false ("port zero", l_client.parse_url ("http://example.org:0/x"))
			assert_false ("port too big", l_client.parse_url ("http://example.org:70000/x"))
		end

feature -- Test: header assembly

	test_header_block_assembly
		note
			testing: "covers/{SIMPLE_WINHTTP}.header_block"
		local
			l_client: SIMPLE_WINHTTP
			l_headers: HASH_TABLE [STRING_8, STRING_8]
			l_block: STRING_8
		do
			create l_client.make
			create l_headers.make (2)
			assert_strings_equal ("empty table, empty block", "", l_client.header_block (l_headers))
			l_headers.put ("application/json", "Content-Type")
			l_block := l_client.header_block (l_headers)
			assert_strings_equal ("one wire line", "Content-Type: application/json%R%N", l_block)
			l_headers.put ("Bearer abc123", "Authorization")
			l_block := l_client.header_block (l_headers)
			assert_true ("both lines present", l_block.has_substring ("Content-Type: application/json%R%N")
				and l_block.has_substring ("Authorization: Bearer abc123%R%N"))
			assert_true ("crlf-terminated", l_block.ends_with ("%R%N"))
		end

	test_header_table_validation
			-- CR, LF and colon-in-name cannot pass the boundary: header
			-- injection dies at the precondition.
		note
			testing: "covers/{SIMPLE_WINHTTP}.is_header_table_clean"
		local
			l_client: SIMPLE_WINHTTP
			l_headers: HASH_TABLE [STRING_8, STRING_8]
		do
			create l_client.make
			create l_headers.make (1)
			l_headers.put ("application/json", "Content-Type")
			assert_true ("clean table passes", l_client.is_header_table_clean (l_headers))
			create l_headers.make (1)
			l_headers.put ("evil%R%NX-Injected: yes", "Content-Type")
			assert_false ("crlf value refused", l_client.is_header_table_clean (l_headers))
			create l_headers.make (1)
			l_headers.put ("v", "Bad:Name")
			assert_false ("colon in name refused", l_client.is_header_table_clean (l_headers))
			create l_headers.make (1)
			l_headers.put ("v", "")
			assert_false ("empty name refused", l_client.is_header_table_clean (l_headers))
		end

feature -- Test: guard predicates

	test_known_methods
		note
			testing: "covers/{SIMPLE_WINHTTP}.is_known_method"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("GET", l_client.is_known_method ("GET"))
			assert_true ("POST", l_client.is_known_method ("POST"))
			assert_true ("DELETE", l_client.is_known_method ("DELETE"))
			assert_true ("PUT", l_client.is_known_method ("PUT"))
			assert_false ("lowercase refused", l_client.is_known_method ("get"))
			assert_false ("garbage refused", l_client.is_known_method ("BREW"))
		end

	test_ascii_url_check
		note
			testing: "covers/{SIMPLE_WINHTTP}.is_ascii_url"
		local
			l_client: SIMPLE_WINHTTP
		do
			create l_client.make
			assert_true ("plain ascii", l_client.is_ascii_url ("http://example.org/a?b=c"))
			assert_false ("space refused", l_client.is_ascii_url ("http://example.org/a b"))
			assert_false ("empty refused", l_client.is_ascii_url (""))
			assert_false ("high byte refused", l_client.is_ascii_url ("http://example.org/" + (create {STRING_8}.make_filled ('%/200/', 1))))
		end

feature -- Test: the response object

	test_response_answer_queries
		note
			testing: "covers/{SIMPLE_WINHTTP_RESPONSE}.make"
		local
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_response.make (200, "{%"store%": true}", "HTTP/1.1 200 OK%R%NContent-Type: application/json%R%N%R%N")
			assert_true ("exchanged", l_response.is_exchanged)
			assert_true ("success", l_response.is_success)
			assert_false ("not a redirect", l_response.is_redirect)
			assert_integers_equal ("status", 200, l_response.status)
			assert_true ("body kept", l_response.body.has_substring ("store"))
			assert_true ("error empty", l_response.error.is_empty)
			if attached l_response.header ("content-type") as l_kind then
				assert_strings_equal ("case-insensitive header lookup", "application/json", l_kind)
			else
				assert_true ("Content-Type found", False)
			end
			assert_true ("absent header is Void", l_response.header ("X-Missing") = Void)
		end

	test_response_redirect_surfaces_location
			-- A 3xx is an ordinary answer: classified, its Location
			-- surfaced - and by construction nothing was followed.
		note
			testing: "covers/{SIMPLE_WINHTTP_RESPONSE}.is_redirect"
		local
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_response.make (302, "hop", "HTTP/1.1 302 Found%R%NLocation: https://elsewhere.example/next%R%N%R%N")
			assert_true ("exchanged", l_response.is_exchanged)
			assert_true ("classified 3xx", l_response.is_redirect)
			assert_false ("not success", l_response.is_success)
			if attached l_response.location as l_where then
				assert_strings_equal ("location surfaced", "https://elsewhere.example/next", l_where)
			else
				assert_true ("Location found", False)
			end
		end

	test_response_failure
		note
			testing: "covers/{SIMPLE_WINHTTP_RESPONSE}.make_failed"
		local
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_response.make_failed ("cannot connect")
			assert_false ("not exchanged", l_response.is_exchanged)
			assert_integers_equal ("status zero", 0, l_response.status)
			assert_true ("explained", not l_response.error.is_empty)
			assert_true ("no body", l_response.body.is_empty)
			assert_true ("no headers", l_response.raw_headers.is_empty)
		end

feature -- Test: network conditions are results

	test_connection_refused_is_a_result
			-- Nothing listens on 8131: the exchange must come back as a
			-- failed RESPONSE - error text, status 0, no exception. This
			-- is the consumer contract's load-bearing clause.
		note
			testing: "covers/{SIMPLE_WINHTTP}.send"
		local
			l_client: SIMPLE_WINHTTP
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_client.make
			l_client.set_connect_timeout_seconds (3)
			l_response := l_client.get ("http://127.0.0.1:8131/nobody-home")
			assert_false ("not exchanged", l_response.is_exchanged)
			assert_integers_equal ("status zero", 0, l_response.status)
			assert_true ("explained", not l_response.error.is_empty)
			assert_integers_equal ("attempt counted", 1, l_client.exchange_count)
		end

end
