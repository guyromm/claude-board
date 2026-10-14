-- Name: FUNCTION whoami(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.whoami() FROM PUBLIC;
GRANT ALL ON FUNCTION api.whoami() TO board_agent;
GRANT ALL ON FUNCTION api.whoami() TO board_admin;


--
