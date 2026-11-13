-- Name: FUNCTION task_project(id bigint); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.task_project(id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION board.task_project(id bigint) TO board_agent;
GRANT ALL ON FUNCTION board.task_project(id bigint) TO board_admin;


--
