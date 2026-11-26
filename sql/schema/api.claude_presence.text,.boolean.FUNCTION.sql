-- Name: claude_presence(text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.claude_presence(p_url text DEFAULT NULL::text, p_load boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
  BEGIN
    IF NOT board.is_admin() THEN RETURN; END IF;
    PERFORM board.claude_session_touch(p_url, p_load, 0);
  END $$;


--
