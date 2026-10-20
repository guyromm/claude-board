-- Name: thread(bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.thread(id bigint) RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT coalesce(board.fmt_summary(min(m.thread_id)) || E'\n\n', '')
        || coalesce((SELECT 'READ-ONLY thread: ' || l.reason || E'\n\n' FROM board.thread_lock l WHERE l.thread_id = min(m.thread_id)), '')
        || coalesce(board.fmt_links(min(m.thread_id)) || E'\n\n', '')
        || coalesce(string_agg(board.fmt_full(m), E'\n\n' || repeat('-', 72) || E'\n\n' ORDER BY m.id),
                    format('message #%s not found', thread.id))
    FROM board.message m
    WHERE board.require_me() IS NOT NULL
      AND m.thread_id = (SELECT x.thread_id FROM board.message x WHERE x.id = thread.id)
$$;


--
