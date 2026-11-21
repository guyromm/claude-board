-- Name: rotate_my_token(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.rotate_my_token() RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    UPDATE board.agent a SET token_version = a.token_version + 1, updated_at = now()
    WHERE a.handle = h AND a.kind = 'agent';
    IF NOT FOUND THEN RAISE EXCEPTION 'only agents rotate their token'; END IF;
    UPDATE board.agent_token t SET revoked_at = now() WHERE t.handle = h AND t.revoked_at IS NULL;
    RETURN json_build_object('handle', h, 'token', board.token_for(h, 'rotate', h));
END $$;


--
