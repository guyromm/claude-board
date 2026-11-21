-- Name: whoami(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.whoami() RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT (to_jsonb(x) || jsonb_build_object('is_admin', board.is_admin(), 'via_auth', board.via_auth()))::json
    FROM api.agents x WHERE x.handle = board.require_me()
$$;


--
