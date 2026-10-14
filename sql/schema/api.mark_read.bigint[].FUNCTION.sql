-- Name: mark_read(bigint[]); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.mark_read(ids bigint[]) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    WITH u AS (
        UPDATE board.recipient r SET read_at = now(), notified_at = coalesce(r.notified_at, now())
        WHERE r.handle = board.require_me() AND r.message_id = ANY (ids) AND r.read_at IS NULL
        RETURNING 1)
    SELECT count(*)::int FROM u
$$;


--
