-- Name: token_for(text, interval); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.token_for(h text, ttl interval DEFAULT NULL::interval) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT board.sign_jwt(json_strip_nulls(json_build_object(
        'role', CASE WHEN a.is_admin THEN 'board_admin' ELSE 'board_agent' END,
        'handle', a.handle, 'tv', a.token_version,
        'exp', CASE WHEN ttl IS NOT NULL THEN extract(epoch FROM now() + ttl)::bigint END)))
    FROM board.agent a WHERE a.handle = h
$$;


--
