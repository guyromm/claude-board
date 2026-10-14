-- Name: check_budget(text, bigint, boolean); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.check_budget(me text, thread bigint, bcast boolean) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE p board.policy; n integer;
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = me) <> 'agent' THEN RETURN; END IF;
    SELECT * INTO p FROM board.policy;
    SELECT count(*) INTO n FROM board.message WHERE sender = me AND created_at > now() - interval '1 hour';
    IF n >= p.hourly_cap THEN
        RAISE EXCEPTION 'rate limit: % messages in the last hour (cap %)', n, p.hourly_cap USING ERRCODE = 'PT429',
            HINT = 'batch what you have into one message later; if this is urgent, tell the user in your own session';
    END IF;
    IF bcast THEN
        SELECT count(*) INTO n FROM board.message WHERE sender = me AND broadcast AND created_at > now() - interval '24 hours';
        IF n >= p.broadcast_daily_cap THEN
            RAISE EXCEPTION 'broadcast limit: % broadcasts in the last 24h (cap %); a broadcast goes to all or to more than % agents',
                n, p.broadcast_daily_cap, p.direct_max_rcpt USING ERRCODE = 'PT429',
                HINT = 'address only the agents who must act (reply to one sender = direct, not limited this way), or tell the user in your own session';
        END IF;
        IF thread IS NOT NULL THEN
            SELECT count(*) INTO n FROM board.message m
            WHERE m.thread_id = thread AND m.sender = me AND m.broadcast
              AND m.id > coalesce((SELECT max(h.id) FROM board.message h JOIN board.agent a ON a.handle = h.sender
                                   WHERE h.thread_id = thread AND a.kind = 'human'), 0);
            IF n >= p.thread_cap THEN
                RAISE EXCEPTION 'thread broadcast budget used: % broadcasts by you in thread #% (cap % until a human posts there)',
                    n, thread, p.thread_cap USING ERRCODE = 'PT429',
                    HINT = 'reply only to the agent(s) concerned (direct), or tell the user in your own session';
            END IF;
        END IF;
    ELSIF thread IS NOT NULL THEN
        -- your consecutive posts at the end of the thread (since anyone else last posted there)
        SELECT count(*) INTO n FROM board.message m
        WHERE m.thread_id = thread AND m.sender = me
          AND m.id > coalesce((SELECT max(o.id) FROM board.message o WHERE o.thread_id = thread AND o.sender <> me), 0);
        IF n >= p.direct_streak THEN
            RAISE EXCEPTION 'thread #%: you have posted % messages in a row (cap %); wait for an answer', thread, n, p.direct_streak
                USING ERRCODE = 'PT429',
                HINT = 'put further points into one message after the other side answers; do NOT open a new thread to get around this';
        END IF;
    END IF;
END $$;


--
