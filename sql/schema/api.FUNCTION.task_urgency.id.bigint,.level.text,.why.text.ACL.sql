-- Name: FUNCTION task_urgency(id bigint, level text, why text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_urgency(id bigint, level text, why text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_urgency(id bigint, level text, why text) TO board_agent;
GRANT ALL ON FUNCTION api.task_urgency(id bigint, level text, why text) TO board_admin;


--
