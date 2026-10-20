-- Name: FUNCTION push_unsubscribe(endpoint text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.push_unsubscribe(endpoint text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.push_unsubscribe(endpoint text) TO board_agent;
GRANT ALL ON FUNCTION api.push_unsubscribe(endpoint text) TO board_admin;


--
