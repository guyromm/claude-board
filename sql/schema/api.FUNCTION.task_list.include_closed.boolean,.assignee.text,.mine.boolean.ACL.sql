-- Name: FUNCTION task_list(include_closed boolean, assignee text, mine boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_list(include_closed boolean, assignee text, mine boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_list(include_closed boolean, assignee text, mine boolean) TO board_agent;
GRANT ALL ON FUNCTION api.task_list(include_closed boolean, assignee text, mine boolean) TO board_admin;


--
