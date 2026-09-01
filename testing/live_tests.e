note
	description: "[
		Live LOCAL integration - no internet, ever. Two localhost
		helpers, each optional:

		* the simple_chat server on 127.0.0.1:8130 (booted by the
		  harness: scratch config, --create-admin larry, serve) - proves
		  GET /health, POST /login with a JSON body and Content-Type
		  header, and a 404 route through the real WinHTTP path;

		* a redirect helper on 127.0.0.1:8132 answering 302 with a
		  Location - proves a 3xx comes back AS the reply, Location
		  surfaced, target body never fetched.

		A test whose helper is not listening prints SKIP and passes:
		the suite stays green on a bare machine, and runs the real
		proof whenever the harness boots the helpers.
	]"
	author: "Larry Rix"
	testing: "covers"

class
	LIVE_TESTS

inherit
	TEST_SET_BASE

feature -- Test: against the simple_chat server (127.0.0.1:8130)

	test_live_health
			-- GET /health answers 200 with the store flag in the body.
		note
			testing: "covers/{SIMPLE_WINHTTP}.get"
		local
			l_client: SIMPLE_WINHTTP
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_client.make
			if answers (Chat_base + "/health") then
				l_response := l_client.get (Chat_base + "/health")
				assert_true ("exchanged", l_response.is_exchanged)
				assert_integers_equal ("200", 200, l_response.status)
				assert_true ("body reports the store", l_response.body.has_substring ("store"))
			else
				print ("  SKIP (no simple_chat server on 8130): test_live_health%N")
			end
		end

	test_live_login
			-- POST /login with the JSON body and a Content-Type header:
			-- 200 and a token in the body.
		note
			testing: "covers/{SIMPLE_WINHTTP}.send"
		local
			l_client: SIMPLE_WINHTTP
			l_headers: HASH_TABLE [STRING_8, STRING_8]
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_client.make
			if answers (Chat_base + "/health") then
				create l_headers.make (1)
				l_headers.put ("application/json", "Content-Type")
				l_response := l_client.send ("POST", Chat_base + "/login", l_headers,
					"{%"username%": %"larry%", %"password%": %"hunter2secure%"}", 10)
				assert_true ("exchanged", l_response.is_exchanged)
				assert_integers_equal ("200", 200, l_response.status)
				assert_true ("token issued", l_response.body.has_substring ("token"))
			else
				print ("  SKIP (no simple_chat server on 8130): test_live_login%N")
			end
		end

	test_live_not_found
			-- An unknown route is an exchanged 404, not a failure.
		note
			testing: "covers/{SIMPLE_WINHTTP}.get"
		local
			l_client: SIMPLE_WINHTTP
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_client.make
			if answers (Chat_base + "/health") then
				l_response := l_client.get (Chat_base + "/no-such-route")
				assert_true ("exchanged", l_response.is_exchanged)
				assert_integers_equal ("404", 404, l_response.status)
			else
				print ("  SKIP (no simple_chat server on 8130): test_live_not_found%N")
			end
		end

feature -- Test: against the redirect helper (127.0.0.1:8132)

	test_live_redirect_not_followed
			-- The 302 IS the reply: Location surfaced, and the target's
			-- distinctive body ("TARGET-REACHED") is nowhere in it -
			-- WinHTTP's follow-redirects default really is disabled.
		note
			testing: "covers/{SIMPLE_WINHTTP}.send"
		local
			l_client: SIMPLE_WINHTTP
			l_response: SIMPLE_WINHTTP_RESPONSE
		do
			create l_client.make
			if answers (Redirect_base + "/probe") then
				l_response := l_client.get (Redirect_base + "/redirect")
				assert_true ("exchanged", l_response.is_exchanged)
				assert_integers_equal ("302 surfaces", 302, l_response.status)
				assert_true ("a redirect", l_response.is_redirect)
				if attached l_response.location as l_where then
					assert_true ("location names the target", l_where.has_substring ("/target"))
				else
					assert_true ("Location header surfaced", False)
				end
				assert_false ("target body never fetched", l_response.body.has_substring ("TARGET-REACHED"))
			else
				print ("  SKIP (no redirect helper on 8132): test_live_redirect_not_followed%N")
			end
		end

feature {NONE} -- Harness plumbing

	Chat_base: STRING_8 = "http://127.0.0.1:8130"
			-- Where the harness boots the simple_chat server.

	Redirect_base: STRING_8 = "http://127.0.0.1:8132"
			-- Where the harness boots the redirect helper.

	answers (a_url: STRING_8): BOOLEAN
			-- Is something listening behind `a_url'? (Any answered
			-- status counts; a probe burns one exchange on a throwaway
			-- client, so test assertions never depend on it.)
		local
			l_probe: SIMPLE_WINHTTP
		do
			create l_probe.make
			l_probe.set_connect_timeout_seconds (2)
			l_probe.set_receive_timeout_seconds (5)
			Result := l_probe.get (a_url).is_exchanged
		end

end
