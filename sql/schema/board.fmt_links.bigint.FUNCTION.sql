-- Name: fmt_links(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_links(t bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT string_agg(format('%s #%s "%s"%s', l.rel, l.linked_id, l.linked_subject,
                             coalesce(' [' || l.linked_status || CASE WHEN l.linked_needs_human THEN ', needs human' ELSE '' END || ']', '')),
                      E'\n' ORDER BY l.linked_id)
    FROM api.thread_links l
    WHERE l.thread_id = t
$$;


--
