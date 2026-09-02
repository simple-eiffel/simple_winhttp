note
	description: "[
		A raw loopback listener that answers slowly, so an exchange
		through SIMPLE_WINHTTP can be held open for a known number of
		seconds with no server, no fixture and no other library.

		It accepts one connection at a time, drains the request, waits
		INSIDE EXECUTION_ENVIRONMENT.sleep - which EiffelBase itself
		marks `C blocking', so this processor's own wait never stops
		anyone's allocator and cannot be mistaken for the thing under
		test - and only then writes a minimal HTTP/1.1 answer and
		closes.

		Every EiffelNet external this class reaches (`c_accept',
		`c_read_stream', `c_put_stream') is marked `C blocking' in
		ISE's own socket.e. That is what makes this listener a clean
		instrument: the ONLY unmarked wait anywhere in the assault is
		the one being measured.

		The port is chosen at run time from a small range, so a busy
		machine does not fail the suite; `port' is 0 when none of them
		was free.
	]"
	author: "Larry Rix"

class
	SLOW_HTTP_LISTENER

create
	make

feature {NONE} -- Initialization

	make (a_delay_milliseconds: INTEGER)
			-- A listener that holds every exchange open for
			-- `a_delay_milliseconds' before answering.
		require
			positive: a_delay_milliseconds > 0
		do
			delay_milliseconds := a_delay_milliseconds
		ensure
			set: delay_milliseconds = a_delay_milliseconds
			not_listening: not is_listening
			nothing_served: served = 0
		end

feature -- Access

	port: INTEGER
			-- The loopback port this listener took, 0 when none was free.

	delay_milliseconds: INTEGER
			-- How long every answer is held back.

	served: INTEGER
			-- Exchanges answered so far.

feature -- Status report

	is_listening: BOOLEAN
			-- Is a bound, listening socket in hand?

	is_finished: BOOLEAN
			-- Has `serve' run to the end?

feature -- Basic operations

	open (a_first_port, a_tries: INTEGER)
			-- Bind and listen on the first free port in
			-- `a_first_port' .. `a_first_port' + `a_tries' - 1.
		require
			positive: a_first_port > 0 and a_tries > 0
			not_open: not is_listening
		local
			l_socket: NETWORK_STREAM_SOCKET
			i: INTEGER
		do
			from
				i := 0
			until
				is_listening or i >= a_tries
			loop
				create l_socket.make_loopback_server_by_port (a_first_port + i)
				if l_socket.is_bound then
					l_socket.set_accept_timeout (Accept_timeout_milliseconds)
					l_socket.listen (Backlog)
					listener := l_socket
					port := a_first_port + i
					is_listening := True
				else
					l_socket.cleanup
				end
				i := i + 1
			variant
				a_tries - i
			end
		ensure
			port_when_listening: is_listening implies port > 0
		end

	serve (a_count: INTEGER)
			-- Answer `a_count' exchanges, each held back by
			-- `delay_milliseconds'. An accept that times out simply ends
			-- that round, so a caller that never arrives cannot hang the
			-- suite.
		require
			listening: is_listening
			positive: a_count > 0
		local
			l_env: EXECUTION_ENVIRONMENT
			i: INTEGER
		do
			create l_env
			from
				i := 1
			until
				i > a_count
			loop
				if attached listener as l_listener then
					l_listener.accept
					if attached l_listener.accepted as l_exchange then
						l_exchange.set_timeout_ns (Exchange_timeout_nanoseconds)
						drain_request (l_exchange)
						l_env.sleep (delay_milliseconds.to_integer_64 * 1_000_000)
						l_exchange.put_string (Reply)
						l_exchange.cleanup
						served := served + 1
					end
				end
				i := i + 1
			variant
				a_count + 1 - i
			end
			is_finished := True
		ensure
			finished: is_finished
			no_more_than_asked: served <= old served + a_count
		end

	shut
			-- Close the listening socket.
		do
			if attached listener as l_listener then
				l_listener.cleanup
			end
			listener := Void
			is_listening := False
		ensure
			closed: not is_listening
		end

feature {NONE} -- Implementation

	listener: detachable NETWORK_STREAM_SOCKET
			-- The bound, listening socket.

	drain_request (a_exchange: NETWORK_STREAM_SOCKET)
			-- Read the request head off `a_exchange', so closing after the
			-- answer sends a FIN and not an RST (an RST can discard a reply
			-- the peer has not read yet).
		local
			l_seen: STRING_8
			l_reads: INTEGER
		do
			create l_seen.make (Read_chunk)
			from
			until
				l_seen.has_substring (Head_end) or l_reads >= Maximum_reads
					or a_exchange.was_error or not a_exchange.ready_for_reading
			loop
				a_exchange.read_stream (Read_chunk)
				if a_exchange.bytes_read > 0 then
					l_seen.append (a_exchange.last_string)
					l_reads := l_reads + 1
				else
					l_reads := Maximum_reads
				end
			variant
				Maximum_reads - l_reads
			end
		end

feature -- Constants

	Reply: STRING_8 = "HTTP/1.1 200 OK%R%NContent-Type: text/plain%R%NContent-Length: 2%R%NConnection: close%R%N%R%Nok"
			-- The whole answer: a minimal, well-formed HTTP/1.1 reply.

	Head_end: STRING_8 = "%R%N%R%N"
			-- End of a request head.

	Backlog: INTEGER = 4

	Read_chunk: INTEGER = 4096

	Maximum_reads: INTEGER = 8
			-- A request head this listener ever sees is one segment; eight
			-- reads is a ceiling, not an expectation.

	Accept_timeout_milliseconds: INTEGER = 20_000
			-- A caller that never arrives ends the round instead of hanging it.

	Exchange_timeout_nanoseconds: NATURAL_64 = 5_000_000_000
			-- Five seconds: what `ready_for_reading' waits on the accepted socket.

invariant
	non_negative_served: served >= 0
	positive_delay: delay_milliseconds > 0
	port_when_listening: is_listening implies port > 0

end
