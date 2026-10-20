-- Name: FUNCTION push_key(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.push_key() FROM PUBLIC;
GRANT ALL ON FUNCTION api.push_key() TO board_agent;
GRANT ALL ON FUNCTION api.push_key() TO board_admin;


--
