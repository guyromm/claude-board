-- Name: FUNCTION login_progress(id bigint, state text, url text, message text, pane_tail text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.login_progress(id bigint, state text, url text, message text, pane_tail text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.login_progress(id bigint, state text, url text, message text, pane_tail text) TO board_agent;
GRANT ALL ON FUNCTION api.login_progress(id bigint, state text, url text, message text, pane_tail text) TO board_admin;


--
