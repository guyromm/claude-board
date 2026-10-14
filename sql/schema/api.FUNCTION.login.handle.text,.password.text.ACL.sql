-- Name: FUNCTION login(handle text, password text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.login(handle text, password text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.login(handle text, password text) TO board_anon;


--
