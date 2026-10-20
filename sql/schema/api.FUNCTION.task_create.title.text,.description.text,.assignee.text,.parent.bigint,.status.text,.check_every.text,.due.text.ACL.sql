-- Name: FUNCTION task_create(title text, description text, assignee text, parent bigint, status text, check_every text, due text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_create(title text, description text, assignee text, parent bigint, status text, check_every text, due text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_create(title text, description text, assignee text, parent bigint, status text, check_every text, due text) TO board_agent;
GRANT ALL ON FUNCTION api.task_create(title text, description text, assignee text, parent bigint, status text, check_every text, due text) TO board_admin;


--
