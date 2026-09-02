note
	description: "[
		THE FREEZE ASSAULT (0.1.1). The vector test for the defect Larry's
		simple_chat window found on 2026-09-02: the chat window stopped
		dead for 8 to 25 seconds at a time - 13 stalls, 211 s frozen in
		one 20 minute session - and Windows ghosted it and threw the
		keystrokes away.

		Nothing in that client's wiring was to blame. What stopped was
		the ROOT PROCESSOR'S ALLOCATOR. ISE's garbage collector stops
		every thread of the system before it collects; a thread inside a
		plain `external "C inline"' call is where the runtime cannot see
		it and cannot stop it, so the collection WAITS for that call to
		return and every other processor waits with it, at its very next
		allocation. SIMPLE_WINHTTP.c_send carried no `blocking' marker,
		and one long poll spends 25 s inside it.

		Four tests, in the order the argument runs:

		1-3  THE LAW (BLOCKING_PROBE). The same wait, three ways: an
		     Eiffel sleep costs the root nothing; an UNMARKED C call
		     costs it the whole wait; the same call MARKED `blocking'
		     costs it nothing again. Test 2 asserts the freeze exists -
		     it is the mechanism, and it passes before and after the fix.

		4    THE VECTOR. A real SIMPLE_WINHTTP on its own processor,
		     against a real loopback listener that holds the answer back
		     three seconds, while the root does nothing but allocate. On
		     0.1.0 the root's worst single allocation was in the
		     thousands of milliseconds. With `c_send' marked, it is
		     single-digit. The budget is 500 ms - a bound with margin,
		     and far under the ~5 s at which Windows ghosts a window.

		Every OTHER wait in this assault is marked: EXECUTION_ENVIRONMENT
		.sleep and every EiffelNet socket external are `C blocking' in
		ISE's own sources. The one unmarked wait is the one under test.
	]"
	author: "Larry Rix"

class
	SCOOP_TEST_APP

inherit
	PRECISE_CLOCK

create
	make

feature {NONE} -- Initialization

	make
			-- Run the assault.
		do
			print ("SIMPLE_WINHTTP freeze assault (SCOOP): a waiting external must not stop the collector%N%N")
			passed := 0
			failed := 0

			run_test (agent test_an_eiffel_sleep_on_another_processor_never_stops_the_allocator,
				"an Eiffel sleep on another processor never stops the allocator")
			run_test (agent test_an_unmarked_c_call_on_another_processor_stops_the_allocator,
				"an unmarked C call on another processor stops the allocator")
			run_test (agent test_a_blocking_marked_c_call_never_stops_the_allocator,
				"a blocking-marked C call never stops the allocator")
			run_test (agent test_a_slow_exchange_never_stops_another_processors_allocator,
				"a slow SIMPLE_WINHTTP exchange never stops another processor's allocator")

			print ("%N========================%N")
			print ("Results: " + passed.out + " passed, " + failed.out + " failed%N")
			if failed > 0 then
				print ("TESTS FAILED%N")
				(create {EXCEPTIONS}).die (1)
			else
				print ("ALL TESTS PASSED%N")
			end
		end

feature {NONE} -- Tests: the law

	test_an_eiffel_sleep_on_another_processor_never_stops_the_allocator
			-- EXECUTION_ENVIRONMENT.sleep is marked for the runtime, so a
			-- processor asleep in it never holds the collector.
		local
			l_probe: separate BLOCKING_PROBE
			l_worst: INTEGER_64
			l_done: INTEGER
		do
			create l_probe.make
			launch_eiffel_sleeps (l_probe)
			l_worst := worst_allocation_burst (Probe_bursts, Probe_gap_ms)
			l_done := waits_made (l_probe)
			print ("      an Eiffel sleep of " + (Probe_waits * Probe_wait_ms).out
				+ " ms on another processor: worst allocation on the root " + l_worst.out + " ms%N")
			assert ("the probe waited", l_done = Probe_waits)
			assert ("a marked wait leaves the root's allocator alone (" + l_worst.out + " ms)",
				l_worst <= Allocation_budget_ms)
		end

	test_an_unmarked_c_call_on_another_processor_stops_the_allocator
			-- THE MECHANISM. The same wait spent inside an unmarked external:
			-- the root's very next allocation waits for it. This is the freeze,
			-- and it is still true after the fix - which is the point. What
			-- changed in 0.1.1 is that SIMPLE_WINHTTP no longer makes one.
		local
			l_probe: separate BLOCKING_PROBE
			l_worst: INTEGER_64
			l_done: INTEGER
		do
			create l_probe.make
			launch_unmarked_c_sleeps (l_probe)
			l_worst := worst_allocation_burst (Probe_bursts, Probe_gap_ms)
			l_done := waits_made (l_probe)
			print ("      an UNMARKED C call of " + Probe_wait_ms.out
				+ " ms on another processor: worst allocation on the root " + l_worst.out + " ms%N")
			assert ("the probe waited", l_done = Probe_waits)
			assert ("an unmarked wait stops the root's allocator for very nearly that long ("
				+ l_worst.out + " ms)", l_worst >= Probe_wait_ms // 2)
		end

	test_a_blocking_marked_c_call_never_stops_the_allocator
			-- THE FIX, in one keyword. The SAME Sleep, marked
			-- `external "C blocking inline"': the root allocates through it.
		local
			l_probe: separate BLOCKING_PROBE
			l_worst: INTEGER_64
			l_done: INTEGER
		do
			create l_probe.make
			launch_blocking_c_sleeps (l_probe)
			l_worst := worst_allocation_burst (Probe_bursts, Probe_gap_ms)
			l_done := waits_made (l_probe)
			print ("      a BLOCKING-marked C call of " + Probe_wait_ms.out
				+ " ms on another processor: worst allocation on the root " + l_worst.out + " ms%N")
			assert ("the probe waited", l_done = Probe_waits)
			assert ("the marker gives the collector the thread back (" + l_worst.out + " ms)",
				l_worst <= Allocation_budget_ms)
		end

feature {NONE} -- Tests: the vector

	test_a_slow_exchange_never_stops_another_processors_allocator
			-- THE RED-THEN-GREEN. A real SIMPLE_WINHTTP.get on its own
			-- processor against a loopback listener that holds every answer
			-- back three seconds, while the root does nothing but allocate.
			--
			-- 0.1.0 (`c_send' unmarked): worst allocation in the thousands
			-- of ms - the chat window's freeze, reproduced in the library
			-- that caused it. 0.1.1 (`c_send' marked `blocking'): single
			-- digits.
		local
			l_listener: separate SLOW_HTTP_LISTENER
			l_caller: separate WINHTTP_CALLER
			l_port, l_served, l_ok: INTEGER
			l_worst, l_call_ms: INTEGER_64
		do
			create l_listener.make (Exchange_delay_ms)
			open_listener (l_listener, First_port, Port_tries)
			l_port := listener_port (l_listener)
			assert ("a loopback port in " + First_port.out + ".." + (First_port + Port_tries - 1).out
				+ " was free for the listener", l_port > 0)
			serve_exchanges (l_listener, Exchanges)
			create l_caller.make
			fetch_exchanges (l_caller, l_port, Exchanges)

			l_worst := worst_allocation_burst (Bursts, Burst_gap_ms)

			l_ok := caller_answered_ok (l_caller)
			l_call_ms := caller_elapsed (l_caller)
			l_served := listener_served (l_listener)
			shut_listener (l_listener)

			print ("      " + Exchanges.out + " exchange(s) of " + Exchange_delay_ms.out
				+ " ms through SIMPLE_WINHTTP on another processor (" + l_call_ms.out
				+ " ms in the transport): worst allocation on the root " + l_worst.out + " ms%N")
			assert ("the listener answered every exchange", l_served = Exchanges)
			assert ("every exchange came back 200", l_ok = Exchanges)
			assert ("the exchanges really were slow ones (" + l_call_ms.out + " ms for "
				+ Exchanges.out + " x " + Exchange_delay_ms.out + " ms)",
				l_call_ms >= (Exchanges * Exchange_delay_ms) * 8 // 10)
			assert ("no allocation on the root waited on the exchange (" + l_worst.out + " ms)",
				l_worst <= Allocation_budget_ms)
		end

feature {NONE} -- The probe's processor (each a short, separate call)

	launch_eiffel_sleeps (a_probe: separate BLOCKING_PROBE)
			-- Start the marked sleeps; asynchronous.
		do
			a_probe.run_eiffel_sleeps (Probe_waits, Probe_wait_ms)
		end

	launch_unmarked_c_sleeps (a_probe: separate BLOCKING_PROBE)
			-- Start the unmarked C waits; asynchronous.
		do
			a_probe.run_unmarked_c_sleeps (Probe_waits, Probe_wait_ms)
		end

	launch_blocking_c_sleeps (a_probe: separate BLOCKING_PROBE)
			-- Start the marked C waits; asynchronous.
		do
			a_probe.run_blocking_c_sleeps (Probe_waits, Probe_wait_ms)
		end

	waits_made (a_probe: separate BLOCKING_PROBE): INTEGER
			-- How many waits the probe made. A query, so it joins the probe.
		do
			Result := a_probe.waits_done
		ensure
			non_negative: Result >= 0
		end

feature {NONE} -- The listener's processor (each a short, separate call)

	open_listener (a_listener: separate SLOW_HTTP_LISTENER; a_first_port, a_tries: INTEGER)
			-- Bind and listen.
		require
			positive: a_first_port > 0 and a_tries > 0
		do
			a_listener.open (a_first_port, a_tries)
		end

	listener_port (a_listener: separate SLOW_HTTP_LISTENER): INTEGER
			-- The port it took, 0 when none was free. A query, so it waits
			-- for `open' to have happened.
		do
			Result := a_listener.port
		ensure
			non_negative: Result >= 0
		end

	serve_exchanges (a_listener: separate SLOW_HTTP_LISTENER; a_count: INTEGER)
			-- Start answering; asynchronous.
		require
			positive: a_count > 0
		do
			a_listener.serve (a_count)
		end

	listener_served (a_listener: separate SLOW_HTTP_LISTENER): INTEGER
			-- How many it answered. A query, so it joins the listener.
		do
			Result := a_listener.served
		ensure
			non_negative: Result >= 0
		end

	shut_listener (a_listener: separate SLOW_HTTP_LISTENER)
			-- Close the listening socket, so the processor goes idle and the
			-- program can end.
		do
			a_listener.shut
		end

feature {NONE} -- The caller's processor (each a short, separate call)

	fetch_exchanges (a_caller: separate WINHTTP_CALLER; a_port, a_count: INTEGER)
			-- Start the GETs; asynchronous, and only integers cross.
		require
			positive: a_port > 0 and a_count > 0
		do
			a_caller.fetch (a_port, a_count)
		end

	caller_answered_ok (a_caller: separate WINHTTP_CALLER): INTEGER
			-- How many came back 200. A query, so it joins the caller.
		do
			Result := a_caller.answered_ok
		ensure
			non_negative: Result >= 0
		end

	caller_elapsed (a_caller: separate WINHTTP_CALLER): INTEGER_64
			-- How long the whole fetch took, in milliseconds.
		do
			Result := a_caller.elapsed_milliseconds
		ensure
			non_negative: Result >= 0
		end

feature {NONE} -- The root's own allocator

	worst_allocation_burst (a_bursts, a_gap_ms: INTEGER): INTEGER_64
			-- Allocate `a_bursts' times, `a_gap_ms' apart, and answer the
			-- longest single burst in milliseconds. Nothing here touches
			-- another processor: a burst that takes a second took it inside
			-- the runtime, waiting for a collection that cannot start.
		require
			positive: a_bursts > 0 and a_gap_ms > 0
		local
			l_env: EXECUTION_ENVIRONMENT
			l_live: ARRAYED_LIST [STRING_8]
			l_junk: ARRAYED_LIST [STRING_8]
			i, k: INTEGER
			t0, l_span: INTEGER_64
		do
			create l_env
			create l_live.make (a_bursts * Burst_kept)
			from
				i := 1
			until
				i > a_bursts
			loop
				t0 := now_ms
				create l_junk.make (Burst_strings)
				from
					k := 1
				until
					k > Burst_strings
				loop
					l_junk.extend (create {STRING_8}.make_filled ('x', Burst_string_bytes))
					if k <= Burst_kept then
							-- A live set that keeps growing, so the collector has
							-- something to mark and cannot answer every burst out
							-- of a free list it already owns.
						l_live.extend (l_junk.last)
					end
					k := k + 1
				variant
					Burst_strings + 1 - k
				end
				l_span := now_ms - t0
				if l_span > Result then
					Result := l_span
				end
				l_env.sleep (a_gap_ms.to_integer_64 * 1_000_000)
				i := i + 1
			variant
				a_bursts + 1 - i
			end
			check kept_them_alive: l_live.count = a_bursts * Burst_kept end
		ensure
			non_negative: Result >= 0
		end

feature {NONE} -- Test runner

	run_test (a_test: PROCEDURE; a_name: STRING_8)
			-- Run one test; any exception (contract or otherwise) fails it.
		local
			l_retried: BOOLEAN
		do
			if not l_retried then
				a_test.call (Void)
				print ("  PASS: " + a_name + "%N")
				passed := passed + 1
			end
		rescue
			print ("  FAIL: " + a_name + "%N")
			if attached (create {EXCEPTION_MANAGER}).last_exception as ex and then attached ex.description as d then
				print ("        " + d.to_string_8 + "%N")
			end
			failed := failed + 1
			l_retried := True
			retry
		end

	assert (a_tag: STRING_8; a_condition: BOOLEAN)
			-- Raise unless `a_condition', so `run_test' records the failure.
		do
			if not a_condition then
				print ("        FAILED: " + a_tag + "%N")
				(create {EXCEPTIONS}).raise ("freeze assault: " + a_tag)
			end
		end

	passed, failed: INTEGER

feature -- Constants: the probe

	Probe_waits: INTEGER = 1
			-- Waits the probe's processor makes.

	Probe_wait_ms: INTEGER = 3_000
			-- How long each of them lasts.

	Probe_bursts: INTEGER = 60

	Probe_gap_ms: INTEGER = 100
			-- 60 x 100 ms = 6 s, twice the probe's whole wait.

feature -- Constants: the vector

	Exchanges: INTEGER = 2
			-- GETs the caller makes through the real transport.

	Exchange_delay_ms: INTEGER = 3_000
			-- How long the listener holds each answer back.

	Bursts: INTEGER = 90

	Burst_gap_ms: INTEGER = 100
			-- 90 x 100 ms = 9 s, comfortably over the 6 s of held exchanges.

	First_port: INTEGER = 18_944

	Port_tries: INTEGER = 20
			-- A busy machine gets the next port, not a failed suite.

feature -- Constants: the bar

	Burst_strings: INTEGER = 2_000

	Burst_string_bytes: INTEGER = 1_024
			-- 2 MiB a burst: enough that the collector runs many times over.

	Burst_kept: INTEGER = 200
			-- 200 KiB of every burst is kept alive, so the heap grows and the
			-- collector has real work: an allocator that is never asked to
			-- collect can never be caught waiting for one.

	Allocation_budget_ms: INTEGER_64 = 500
			-- The bound, with margin. A frame is 16 ms; Windows ghosts a window
			-- that stops pumping for about five seconds. 500 ms is far under
			-- the harm and far over the noise - and the measured GREEN is
			-- single-digit, so nothing here is tuned to just barely pass.

end
