-- Name: thread_link(bigint, bigint, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.thread_link(id bigint, other bigint, kind text DEFAULT 'related'::text, unlink boolean DEFAULT false) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); a bigint; b bigint; k text := lower(btrim(coalesce(thread_link.kind, 'related')));
BEGIN
    SELECT x.thread_id INTO a FROM board.message x WHERE x.id = thread_link.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_link.id; END IF;
    SELECT x.thread_id INTO b FROM board.message x WHERE x.id = thread_link.other;
    IF NOT FOUND THEN RAISE EXCEPTION 'message #% not found', thread_link.other; END IF;
    IF a = b THEN RAISE EXCEPTION '#% and #% are the same thread (#%)', thread_link.id, thread_link.other, a; END IF;
    IF unlink THEN
        DELETE FROM board.thread_link l WHERE l.thread_id = greatest(a, b) AND l.other_id = least(a, b);
        RETURN format('threads #%s and #%s: %s', least(a, b), greatest(a, b), CASE WHEN FOUND THEN 'unlinked' ELSE 'were not linked' END);
    END IF;
    IF k NOT IN ('continues', 'related') THEN RAISE EXCEPTION 'kind must be continues or related, not "%"', k; END IF;
    INSERT INTO board.thread_link AS l (thread_id, other_id, kind, created_by) VALUES (greatest(a, b), least(a, b), k, me)
    ON CONFLICT (thread_id, other_id) DO UPDATE SET kind = EXCLUDED.kind;
    RETURN format('thread #%s %s #%s', greatest(a, b), CASE k WHEN 'continues' THEN 'continues' ELSE 'is related to' END, least(a, b));
END $$;


--
