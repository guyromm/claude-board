-- Name: FUNCTION task_id(ref text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_id(ref text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_id(ref text) TO board_agent;
GRANT ALL ON FUNCTION api.task_id(ref text) TO board_admin;


--
