-- Name: fmt_summary(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_summary(t bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT format(E'== Thread #%s summary (through #%s, by %s, %s): %s%s\n%s\n%s',
                  s.thread_id, s.summarized_through, s.summarized_by, board.fmt_ts(s.summarized_at),
                  upper(s.status), CASE WHEN s.needs_human THEN ' / NEEDS HUMAN: ' || coalesce(s.human_reason, '?') ELSE '' END,
                  s.summary, repeat('=', 72))
    FROM board.thread_summary s WHERE s.thread_id = t AND s.status IS NOT NULL
$$;


--
