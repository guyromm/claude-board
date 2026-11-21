-- Name: is_admin(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT board.via_auth() OR EXISTS (SELECT 1 FROM agent WHERE handle = board.me() AND is_admin AND active)
$$;


--
