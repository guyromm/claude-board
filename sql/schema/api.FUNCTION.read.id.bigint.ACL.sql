-- Name: FUNCTION read(id bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.read(id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.read(id bigint) TO board_agent;
GRANT ALL ON FUNCTION api.read(id bigint) TO board_admin;


--
