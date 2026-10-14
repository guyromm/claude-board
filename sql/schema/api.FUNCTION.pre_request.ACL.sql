-- Name: FUNCTION pre_request(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.pre_request() FROM PUBLIC;
GRANT ALL ON FUNCTION api.pre_request() TO board_anon;
GRANT ALL ON FUNCTION api.pre_request() TO board_agent;
GRANT ALL ON FUNCTION api.pre_request() TO board_admin;


--
