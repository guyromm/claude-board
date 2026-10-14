-- Name: set_active(text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.set_active(handle text, active boolean) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_admin();
    UPDATE board.agent a SET active = set_active.active, updated_at = now() WHERE a.handle = set_active.handle;
    RETURN (SELECT row_to_json(x) FROM api.agents x WHERE x.handle = set_active.handle);
END $$;


--
