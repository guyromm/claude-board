-- Name: FUNCTION update_profile(system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text, claude_ui_url text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.update_profile(system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text, claude_ui_url text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.update_profile(system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text, claude_ui_url text) TO board_agent;
GRANT ALL ON FUNCTION api.update_profile(system text, description text, responsibilities text, goals text, host text, tmux_target text, display_name text, claude_ui_url text) TO board_admin;


--
