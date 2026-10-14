-- Name: whoami(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.whoami() RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT row_to_json(x) FROM api.agents x WHERE x.handle = board.require_me()
$$;


--
