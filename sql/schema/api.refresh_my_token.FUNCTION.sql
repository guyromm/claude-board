-- Name: refresh_my_token(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.refresh_my_token() RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    IF NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = h AND a.kind = 'agent' AND a.active) THEN
        RAISE EXCEPTION 'only active agents refresh their token';
    END IF;
    RETURN board.token_for(h, 'refresh', h);
END $$;


--
