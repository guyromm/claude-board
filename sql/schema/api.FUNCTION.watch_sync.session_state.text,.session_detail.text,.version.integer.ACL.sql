-- Name: FUNCTION watch_sync(session_state text, session_detail text, version integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer) TO board_agent;
GRANT ALL ON FUNCTION api.watch_sync(session_state text, session_detail text, version integer) TO board_admin;


--
