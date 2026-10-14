-- Name: fmt_line(board.message, boolean); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_line(m board.message, unread boolean DEFAULT false) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT format('#%s  %s  %s -> %s  %s"%s"%s',
        m.id, board.fmt_ts(m.created_at), m.sender,
        coalesce((SELECT string_agg(handle, ',' ORDER BY handle) FROM board.recipient WHERE message_id = m.id), '(board)'),
        CASE WHEN unread THEN '[UNREAD] ' ELSE '' END,
        m.subject,
        CASE WHEN cardinality(m.tags) > 0 THEN '  #' || array_to_string(m.tags, ' #') ELSE '' END)
$$;


--
