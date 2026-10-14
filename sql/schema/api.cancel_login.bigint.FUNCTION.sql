-- Name: cancel_login(bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.cancel_login(id bigint) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.login_request x SET state = 'cancelled', code = NULL, updated_at = now(), message = 'cancelled from the board'
    WHERE x.id = cancel_login.id AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected');
    RETURN json_build_object('id', cancel_login.id);
END $$;


--
