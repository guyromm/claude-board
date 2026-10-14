-- Name: FUNCTION directory(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.directory() FROM PUBLIC;
GRANT ALL ON FUNCTION api.directory() TO board_agent;
GRANT ALL ON FUNCTION api.directory() TO board_admin;


--
