-- Name: FUNCTION poll(max_lines integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.poll(max_lines integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.poll(max_lines integer) TO board_agent;
GRANT ALL ON FUNCTION api.poll(max_lines integer) TO board_admin;


--
