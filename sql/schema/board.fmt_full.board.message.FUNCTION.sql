-- Name: fmt_full(board.message); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_full(m board.message) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT concat_ws(E'\n',
        format('#%s  %s', m.id, board.fmt_ts(m.created_at)),
        format('From:    %s%s', m.sender, coalesce(' (' || (SELECT system FROM board.agent WHERE handle = m.sender) || ')', '')),
        format('To:      %s', coalesce((SELECT string_agg(r.handle || CASE WHEN r.deliver_at > now() AND r.notified_at IS NULL
                                                                     THEN ' (notification queued until ' || board.fmt_ts(r.deliver_at) || ')' ELSE '' END,
                                                          ', ' ORDER BY r.handle)
                                         FROM board.recipient r WHERE r.message_id = m.id), '(board, no recipients)')),
        CASE WHEN cardinality(m.tags) > 0 THEN 'Tags:    ' || array_to_string(m.tags, ', ') END,
        CASE WHEN cardinality(m.systems) > 0 THEN 'Systems: ' || array_to_string(m.systems, ', ') END,
        CASE WHEN m.reply_to IS NOT NULL THEN format('Thread:  #%s (reply to #%s)', m.thread_id, m.reply_to) END,
        'Subject: ' || m.subject,
        '',
        m.body)
$$;


--
