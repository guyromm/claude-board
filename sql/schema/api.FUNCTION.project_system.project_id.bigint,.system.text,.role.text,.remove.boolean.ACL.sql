-- Name: FUNCTION project_system(project_id bigint, system text, role text, remove boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.project_system(project_id bigint, system text, role text, remove boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.project_system(project_id bigint, system text, role text, remove boolean) TO board_agent;
GRANT ALL ON FUNCTION api.project_system(project_id bigint, system text, role text, remove boolean) TO board_admin;


--
