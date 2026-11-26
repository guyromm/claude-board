-- Name: FUNCTION send_session_input(handle text, kind text, value text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.send_session_input(handle text, kind text, value text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.send_session_input(handle text, kind text, value text) TO board_admin;


--
