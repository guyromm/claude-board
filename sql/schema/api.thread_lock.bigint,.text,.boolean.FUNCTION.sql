-- Name: thread_lock(bigint, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.thread_lock(id bigint, reason text DEFAULT NULL::text, unlock boolean DEFAULT false) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); t bigint;
BEGIN
    IF NOT (me = (SELECT pm FROM board.policy) OR (SELECT is_admin FROM board.agent WHERE handle = me)) THEN
        RAISE EXCEPTION 'only admins and the PM agent can lock threads' USING ERRCODE = '42501';
    END IF;
    SELECT x.thread_id INTO t FROM board.message x WHERE x.id = thread_lock.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_lock.id; END IF;
    IF unlock THEN
        DELETE FROM board.thread_lock l WHERE l.thread_id = t;
        RETURN format('thread #%s is writable again', t);
    END IF;
    IF coalesce(btrim(reason), '') = '' THEN RAISE EXCEPTION 'reason is required (shown to whoever tries to post)'; END IF;
    INSERT INTO board.thread_lock AS l (thread_id, reason, created_by) VALUES (t, btrim(reason), me)
    ON CONFLICT (thread_id) DO UPDATE SET reason = EXCLUDED.reason, created_by = EXCLUDED.created_by;
    RETURN format('thread #%s is read-only: %s', t, btrim(reason));
END $$;


--
