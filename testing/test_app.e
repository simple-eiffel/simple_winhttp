note
	description: "Test application for SIMPLE_WINHTTP"
	author: "Larry Rix"

class
	TEST_APP

create
	make

feature {NONE} -- Initialization

	make
			-- Run the tests.
		do
			print ("Running SIMPLE_WINHTTP tests...%N%N")
			passed := 0
			failed := 0

			run_lib_tests
			run_live_tests

			print ("%N========================%N")
			print ("Results: " + passed.out + " passed, " + failed.out + " failed%N")

			if failed > 0 then
				print ("TESTS FAILED%N")
				(create {EXCEPTIONS}).die (1)
			else
				print ("ALL TESTS PASSED%N")
			end
		end

feature {NONE} -- Test Runners

	run_lib_tests
		do
			create lib_tests
			run_test (agent lib_tests.test_defaults, "test_defaults")
			run_test (agent lib_tests.test_options_settable, "test_options_settable")
			run_test (agent lib_tests.test_redirect_policy_is_never, "test_redirect_policy_is_never")
			run_test (agent lib_tests.test_parse_http_url, "test_parse_http_url")
			run_test (agent lib_tests.test_parse_https_url, "test_parse_https_url")
			run_test (agent lib_tests.test_parse_url_port_and_query, "test_parse_url_port_and_query")
			run_test (agent lib_tests.test_parse_url_rejections, "test_parse_url_rejections")
			run_test (agent lib_tests.test_header_block_assembly, "test_header_block_assembly")
			run_test (agent lib_tests.test_header_table_validation, "test_header_table_validation")
			run_test (agent lib_tests.test_known_methods, "test_known_methods")
			run_test (agent lib_tests.test_ascii_url_check, "test_ascii_url_check")
			run_test (agent lib_tests.test_response_answer_queries, "test_response_answer_queries")
			run_test (agent lib_tests.test_response_redirect_surfaces_location, "test_response_redirect_surfaces_location")
			run_test (agent lib_tests.test_response_failure, "test_response_failure")
			run_test (agent lib_tests.test_connection_refused_is_a_result, "test_connection_refused_is_a_result")
		end

	run_live_tests
		do
			create live_tests
			run_test (agent live_tests.test_live_health, "test_live_health")
			run_test (agent live_tests.test_live_login, "test_live_login")
			run_test (agent live_tests.test_live_not_found, "test_live_not_found")
			run_test (agent live_tests.test_live_redirect_not_followed, "test_live_redirect_not_followed")
		end

feature {NONE} -- Implementation

	lib_tests: LIB_TESTS

	live_tests: LIVE_TESTS

	passed: INTEGER

	failed: INTEGER

	run_test (a_test: PROCEDURE; a_name: STRING)
			-- Run a single test and update counters.
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
			failed := failed + 1
			l_retried := True
			retry
		end

end
