-- Name: FUNCTION task_link(id bigint, thread bigint, unlink boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_link(id bigint, thread bigint, unlink boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_link(id bigint, thread bigint, unlink boolean) TO board_agent;
GRANT ALL ON FUNCTION api.task_link(id bigint, thread bigint, unlink boolean) TO board_admin;


--
