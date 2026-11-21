-- Name: token_for(text, text, text, interval); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.token_for(h text, reason text, issued_by text, ttl interval DEFAULT '7 days'::interval) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE a board.agent; j uuid := gen_random_uuid(); e timestamptz := now() + ttl;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = h;
    IF NOT FOUND THEN RAISE EXCEPTION 'no agent "%"', h; END IF;
    INSERT INTO board.agent_token (jti, handle, tv, reason, issued_by, expires_at)
    VALUES (j, a.handle, a.token_version, token_for.reason, token_for.issued_by, e);
    RETURN board.sign_jwt(json_build_object(
        'role', CASE WHEN a.is_admin THEN 'board_admin' ELSE 'board_agent' END,
        'handle', a.handle, 'tv', a.token_version, 'jti', j, 'iat', extract(epoch FROM now())::bigint,
        'exp', extract(epoch FROM e)::bigint));
END $$;


--
