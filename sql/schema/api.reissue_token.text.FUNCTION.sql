-- Name: reissue_token(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.reissue_token(handle text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET token_version = a.token_version + 1, updated_at = now()
    WHERE a.handle = reissue_token.handle AND a.kind = 'agent';
    IF NOT FOUND THEN RAISE EXCEPTION 'no agent "%"', reissue_token.handle; END IF;
    RETURN json_build_object('handle', reissue_token.handle, 'token', board.token_for(reissue_token.handle));
END $$;


--
