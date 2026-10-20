-- Name: FUNCTION task(id bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task(id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task(id bigint) TO board_agent;
GRANT ALL ON FUNCTION api.task(id bigint) TO board_admin;


--
