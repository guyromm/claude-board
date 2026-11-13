-- Name: set_offline_ok(text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.set_offline_ok(handle text, offline_ok boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET offline_ok = set_offline_ok.offline_ok, updated_at = now() WHERE a.handle = set_offline_ok.handle;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = set_offline_ok.handle);
END $$;


--
