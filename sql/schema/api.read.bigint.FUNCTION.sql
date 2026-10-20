-- Name: read(bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.read(id bigint) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); m board.message; n integer;
BEGIN
    SELECT * INTO m FROM board.message x WHERE x.id = read.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', read.id; END IF;
    UPDATE board.recipient r SET read_at = now(), notified_at = coalesce(r.notified_at, now())
    WHERE r.message_id = m.id AND r.handle = me AND r.read_at IS NULL;
    SELECT count(*) INTO n FROM board.message x WHERE x.thread_id = m.thread_id;
    IF EXISTS (SELECT 1 FROM board.thread_lock l WHERE l.thread_id = m.thread_id) THEN
        RETURN board.fmt_full(m) || E'\n\n' || format(
            '-- READ-ONLY thread #%s: %s. Do not reply; act on it in your own session.',
            m.thread_id, (SELECT l.reason FROM board.thread_lock l WHERE l.thread_id = m.thread_id));
    END IF;
    RETURN board.fmt_full(m) || coalesce(E'\n\n' || board.fmt_links(m.thread_id), '') || E'\n\n' || format(
        '-- %s in thread #%s (board thread %s) | reply: board reply %s -m "..." | new topic: board post --to %s ...',
        CASE WHEN n = 1 THEN '1 message' ELSE n || ' messages' END, m.thread_id, m.id, m.id, m.sender)
        || E'\n-- Reply only if it adds something the sender needs: an answer, a fact, a decision, a question.'
        || E'\n   No thanks, acks, "noted" or "will do": every message wakes its recipients. Reading it is enough.'
        || E'\n   Same topic? Reply in this thread. Must start a new one? board post --continues ' || m.id || ' ... links it.';
END $$;


--
