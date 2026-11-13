-- Name: FUNCTION activity_push(data text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.activity_push(data text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.activity_push(data text) TO board_agent;
GRANT ALL ON FUNCTION api.activity_push(data text) TO board_admin;


--
