note
	description: "[
		A processor whose whole job is to sit inside SIMPLE_WINHTTP for
		a few seconds - the poller's role in simple_chat, reduced to the
		one thing that matters.

		It takes a port rather than a URL: under SCOOP a non-separate
		reference cannot cross to another processor, and the client
		itself is created here, on this processor, as SIMPLE_WINHTTP's
		own class note requires (one instance per processor).
	]"
	author: "Larry Rix"

class
	WINHTTP_CALLER

inherit
	PRECISE_CLOCK

create
	make

feature {NONE} -- Initialization

	make
			-- A caller that has exchanged nothing.
		do
			create client.make
			client.set_receive_timeout_seconds (Receive_timeout_seconds)
		ensure
			nothing_attempted: attempted = 0
			nothing_exchanged: exchanged = 0
			nothing_spent: elapsed_milliseconds = 0
			not_finished: not is_finished
		end

feature -- Access

	attempted: INTEGER
			-- Exchanges this caller started.

	exchanged: INTEGER
			-- Exchanges that came back with an answer.

	answered_ok: INTEGER
			-- Exchanges that came back 200.

	elapsed_milliseconds: INTEGER_64
			-- Wall-clock time the whole of `fetch' spent, so the assault can
			-- prove the calls really were long ones and not a fast failure.

feature -- Status report

	is_finished: BOOLEAN
			-- Has `fetch' run to the end? (Querying this joins the caller.)

feature -- Basic operations

	fetch (a_port, a_count: INTEGER)
			-- `a_count' GETs against the slow listener on loopback `a_port'.
			-- Each one holds this processor inside `c_send' for as long as
			-- the listener holds the answer back.
		require
			positive: a_port > 0 and a_count > 0
		local
			l_url: STRING_8
			l_response: SIMPLE_WINHTTP_RESPONSE
			i: INTEGER
			t0: INTEGER_64
		do
			t0 := now_ms
			l_url := "http://127.0.0.1:" + a_port.out + "/slow"
			from
				i := 1
			until
				i > a_count
			loop
				attempted := attempted + 1
				l_response := client.get (l_url)
				if l_response.is_exchanged then
					exchanged := exchanged + 1
					if l_response.status = 200 then
						answered_ok := answered_ok + 1
					end
				end
				i := i + 1
			variant
				a_count + 1 - i
			end
			elapsed_milliseconds := now_ms - t0
			is_finished := True
		ensure
			finished: is_finished
			all_attempted: attempted = old attempted + a_count
			timed: elapsed_milliseconds >= 0
		end

feature -- Constants

	Receive_timeout_seconds: INTEGER = 15
			-- Comfortably over the listener's hold, and short enough that a
			-- listener that never answers fails the test in seconds rather
			-- than in minutes.

feature {NONE} -- Implementation

	client: SIMPLE_WINHTTP
			-- This processor's own transport.

invariant
	non_negative: attempted >= 0 and exchanged >= 0 and answered_ok >= 0
	non_negative_elapsed: elapsed_milliseconds >= 0
	exchanged_within_attempted: exchanged <= attempted
	ok_within_exchanged: answered_ok <= exchanged

end
