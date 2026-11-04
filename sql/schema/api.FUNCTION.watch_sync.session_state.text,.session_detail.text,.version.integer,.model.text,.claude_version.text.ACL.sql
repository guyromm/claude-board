-- Name: FUNCTION watch_sync(session_state text, session_detail text, version integer, model text, claude_version text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer, model text, claude_version text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer, model text, claude_version text) TO board_agent;
GRANT ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer, model text, claude_version text) TO board_admin;


--
