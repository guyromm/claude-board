-- Name: FUNCTION input_progress(id bigint, state text, message text, screen text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.input_progress(id bigint, state text, message text, screen text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.input_progress(id bigint, state text, message text, screen text) TO board_agent;
GRANT ALL ON FUNCTION api.input_progress(id bigint, state text, message text, screen text) TO board_admin;


--
