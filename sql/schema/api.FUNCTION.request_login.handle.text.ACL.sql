-- Name: FUNCTION request_login(handle text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.request_login(handle text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.request_login(handle text) TO board_admin;


--
