-- Name: task_id(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_id(ref text) RETURNS api."text/plain"
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE i bigint := board.task_resolve(ref);
BEGIN
    PERFORM board.require_me();
    IF i IS NULL THEN RAISE EXCEPTION 'task % not found', ref; END IF;
    RETURN i::text;
END $$;


--
