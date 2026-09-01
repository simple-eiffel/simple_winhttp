note
	description: "[
		What one exchange brings back: an HTTP status, raw body bytes and
		the raw response headers when the exchange happened, or a
		transport error (no connection, timeout, oversized body) when it
		did not. `status' = 0 exactly when the transport failed.

		A 3xx is an ordinary answer here: SIMPLE_WINHTTP never follows a
		redirect, so `is_redirect' plus `location' is how a caller SEES
		one, decides, and stays in charge of what gets re-sent where.

		Bodies are bytes (STRING_8): JSON arrives as UTF-8 bytes and it
		is the caller's codec that decides what they mean.
	]"
	author: "Larry Rix"

class
	SIMPLE_WINHTTP_RESPONSE

create
	make,
	make_failed

feature {NONE} -- Initialization

	make (a_status: INTEGER; a_body: READABLE_STRING_8; a_raw_headers: READABLE_STRING_8)
			-- An answer from the server: `a_status' with `a_body' bytes and
			-- the raw header block `a_raw_headers' (status line + CRLF lines).
		require
			answered_status: a_status >= 100 and a_status <= 599
		do
			status := a_status
			body := a_body.to_string_8
			raw_headers := a_raw_headers.to_string_8
			create error.make_empty
		ensure
			status_set: status = a_status
			body_set: body.same_string (a_body)
			headers_set: raw_headers.same_string (a_raw_headers)
			exchanged: is_exchanged
			no_error: error.is_empty
		end

	make_failed (a_error: READABLE_STRING_GENERAL)
			-- No exchange: `a_error' says why.
		require
			explained: not a_error.is_empty
		do
			create body.make_empty
			create raw_headers.make_empty
			error := a_error.to_string_32
		ensure
			failed: not is_exchanged
			explained: error.same_string_general (a_error)
			no_body: body.is_empty
			no_headers: raw_headers.is_empty
		end

feature -- Access

	status: INTEGER
			-- HTTP status; 0 when the transport failed.

	body: STRING_8
			-- Raw body bytes (UTF-8 for JSON).

	raw_headers: STRING_8
			-- The response's raw header block: status line, then
			-- "Name: value" lines, CRLF-separated. Empty on failure.

	error: STRING_32
			-- Transport failure reason; empty when `is_exchanged'.

	header (a_name: READABLE_STRING_8): detachable STRING_8
			-- Value of the first response header named `a_name'
			-- (case-insensitive), stripped of surrounding blanks;
			-- Void when the response carries no such header.
		require
			named: not a_name.is_empty
		local
			l_lines: LIST [STRING_8]
			l_colon: INTEGER
			l_name: STRING_8
		do
			l_lines := raw_headers.split ('%N')
			across
				l_lines as ic
			until
				Result /= Void
			loop
				l_colon := ic.index_of (':', 1)
				if l_colon > 1 then
					l_name := ic.substring (1, l_colon - 1)
					l_name.right_adjust
					if l_name.is_case_insensitive_equal (a_name.to_string_8) then
						Result := ic.substring (l_colon + 1, ic.count)
						Result.left_adjust
						Result.right_adjust
						Result.prune_all ('%R')
					end
				end
			end
		ensure
			trimmed: attached Result as l_value implies
				(l_value.is_empty or else (l_value [1] /= ' ' and l_value [l_value.count] /= ' '))
		end

	location: detachable STRING_8
			-- The Location header of a 3xx answer, if any - surfaced,
			-- never acted on.
		do
			Result := header ("Location")
		end

feature -- Status report

	is_exchanged: BOOLEAN
			-- Did a request reach the server and an answer come back?
		do
			Result := status > 0
		ensure
			definition: Result = (status > 0)
		end

	is_success: BOOLEAN
			-- 2xx?
		do
			Result := status >= 200 and status <= 299
		ensure
			definition: Result = (status >= 200 and status <= 299)
		end

	is_redirect: BOOLEAN
			-- 3xx? The transport has NOT followed it; `location' says
			-- where the server pointed.
		do
			Result := status >= 300 and status <= 399
		ensure
			definition: Result = (status >= 300 and status <= 399)
			never_acted_on: True -- Documented guarantee: SIMPLE_WINHTTP surfaces, never follows.
		end

invariant
	body_attached: body /= Void
	headers_attached: raw_headers /= Void
	error_attached: error /= Void
	failed_is_explained: (status = 0) = not error.is_empty
	status_range: status = 0 or (status >= 100 and status <= 599)
	failure_carries_nothing: status = 0 implies (body.is_empty and raw_headers.is_empty)

end
