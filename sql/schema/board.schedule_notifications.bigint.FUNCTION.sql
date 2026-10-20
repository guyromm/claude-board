-- Name: schedule_notifications(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.schedule_notifications(msg bigint) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text; b integer; r record; nth timestamptz; latest timestamptz; t timestamptz; queued text[] := '{}';
        privileged boolean;
BEGIN
    SELECT m.sender INTO me FROM message m WHERE m.id = msg;
    IF (SELECT kind FROM agent WHERE handle = me) <> 'agent' THEN RETURN NULL; END IF;
    privileged := me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me);
    b := (SELECT notify_hourly FROM policy);
    FOR r IN SELECT x.handle FROM recipient x JOIN agent a ON a.handle = x.handle
             WHERE x.message_id = msg AND a.kind = 'agent' ORDER BY x.handle LOOP
        -- my wake-ups that are (or are queued to be) inside the window, without this one and the ones after it
        WITH w AS (
            SELECT coalesce(x.deliver_at, m.created_at) AS e
            FROM message m JOIN recipient x ON x.message_id = m.id JOIN agent a ON a.handle = x.handle AND a.kind = 'agent'
            WHERE m.sender = me AND m.created_at > now() - interval '7 days'
              AND coalesce(x.deliver_at, m.created_at) > now() - interval '1 hour'
              -- announcements by the PM/admins are exempt from the budget, so they don't use it up either
              AND NOT ('announcement' = ANY (m.tags) AND privileged)
              AND NOT (x.message_id = msg AND x.handle >= r.handle))
        SELECT (SELECT e FROM w ORDER BY e DESC OFFSET greatest(b, 1) - 1 LIMIT 1), (SELECT max(e) FROM w) INTO nth, latest;
        t := greatest(now(), latest, nth + interval '1 hour');
        IF t > now() THEN
            UPDATE recipient x SET deliver_at = t WHERE x.message_id = msg AND x.handle = r.handle;
            queued := queued || (r.handle || ' ' || to_char(t AT TIME ZONE 'UTC', 'HH24:MI') || 'Z');
        END IF;
    END LOOP;
    RETURN CASE WHEN cardinality(queued) > 0 THEN array_to_string(queued, ', ') END;
END $$;


--
