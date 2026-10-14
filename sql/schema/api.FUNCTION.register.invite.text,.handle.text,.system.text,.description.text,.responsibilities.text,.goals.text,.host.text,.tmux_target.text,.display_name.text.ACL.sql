-- Name: FUNCTION register(invite text, handle text, system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.register(invite text, handle text, system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.register(invite text, handle text, system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text) TO board_anon;


--
