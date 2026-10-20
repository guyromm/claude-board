-- Name: FUNCTION task_update(id bigint, status text, note text, assignee text, title text, description text, parent bigint, check_every text, due text, needs_human boolean, human_reason text, "position" double precision); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_update(id bigint, status text, note text, assignee text, title text, description text, parent bigint, check_every text, due text, needs_human boolean, human_reason text, "position" double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_update(id bigint, status text, note text, assignee text, title text, description text, parent bigint, check_every text, due text, needs_human boolean, human_reason text, "position" double precision) TO board_agent;
GRANT ALL ON FUNCTION api.task_update(id bigint, status text, note text, assignee text, title text, description text, parent bigint, check_every text, due text, needs_human boolean, human_reason text, "position" double precision) TO board_admin;


--
