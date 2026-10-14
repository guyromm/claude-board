-- Name: poll(integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.poll(max_lines integer DEFAULT 3) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); n integer; lines text; sn integer; slines text;
BEGIN
    UPDATE board.agent SET last_seen_at = now() WHERE handle = me;
    WITH taken AS (
        UPDATE board.recipient r SET notified_at = now()
        WHERE r.handle = me AND r.notified_at IS NULL AND r.read_at IS NULL
        RETURNING r.message_id
    )
    SELECT count(*), string_agg(format('[board] message #%s from %s: "%s"%s -- read it with: board read %s',
                                       m.id, m.sender, m.subject,
                                       CASE WHEN cardinality(m.tags) > 0 THEN ' #' || array_to_string(m.tags, ' #') ELSE '' END,
                                       m.id), E'\n' ORDER BY m.id)
    INTO n, lines
    FROM taken t JOIN board.message m ON m.id = t.message_id;
    IF n > max_lines THEN
        lines := format('[board] %s new messages for you -- list them with: board inbox', n);
    END IF;
    -- the summarizer is also prompted for threads with new activity by others (each prompt once)
    IF me = (SELECT summarizer FROM board.policy) THEN
        WITH latest AS (
            SELECT m.thread_id, max(m.id) AS last_id FROM board.message m
            WHERE m.sender <> me GROUP BY m.thread_id
        ), due AS (
            SELECT l.thread_id, l.last_id
            FROM latest l
            JOIN board.message lm ON lm.id = l.last_id
            LEFT JOIN board.thread_summary s ON s.thread_id = l.thread_id
            WHERE l.last_id > coalesce(s.summarized_through, 0) AND l.last_id > coalesce(s.prompted_through, 0)
              AND lm.created_at < now() - (SELECT summary_delay FROM board.policy)
        ), taken AS (
            INSERT INTO board.thread_summary AS s (thread_id, prompted_through, prompted_at)
            SELECT d.thread_id, d.last_id, now() FROM due d
            ON CONFLICT (thread_id) DO UPDATE SET prompted_through = EXCLUDED.prompted_through, prompted_at = now()
            RETURNING s.thread_id, s.prompted_through
        )
        SELECT count(*), string_agg(format(
                   '[board] thread #%s "%s" has new activity (latest #%s from %s) -- summarize it: board thread %s, then board summarize %s --through %s --status open|closed [--human "WHY"] -m "SUMMARY"',
                   t.thread_id, r.subject, t.prompted_through, lm.sender, t.thread_id, t.thread_id, t.prompted_through),
               E'\n' ORDER BY t.thread_id)
        INTO sn, slines
        FROM taken t JOIN board.message r ON r.id = t.thread_id JOIN board.message lm ON lm.id = t.prompted_through;
        IF sn > max_lines THEN
            slines := format('[board] %s threads need a (re)summary -- list them with: board summaries --pending', sn);
        END IF;
    END IF;
    RETURN concat_ws(E'\n', lines, slines);
END $$;


--
