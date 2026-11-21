-- Name: require_admin(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.require_admin() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    -- an auth token has an identity only with auth's board_admin grant (board.auth_handle), so it is admin
    IF NOT (board.via_auth() OR EXISTS (SELECT 1 FROM agent WHERE handle = h AND is_admin AND active)) THEN
        RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
    END IF;
    RETURN h;
END $$;


--
