-- Name: require_curator(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.require_curator() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE h text := board.require_me();
BEGIN
    IF NOT (board.is_admin() OR h = (SELECT pm FROM board.policy)) THEN
        RAISE EXCEPTION 'admins and the PM agent only' USING ERRCODE = '42501';
    END IF;
    RETURN h;
END $$;


--
