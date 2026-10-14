-- Name: FUNCTION thread(id bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.thread(id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.thread(id bigint) TO board_agent;
GRANT ALL ON FUNCTION api.thread(id bigint) TO board_admin;


--
