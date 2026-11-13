-- Name: FUNCTION project_client(project_id bigint, client text, for_client text, remove boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.project_client(project_id bigint, client text, for_client text, remove boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.project_client(project_id bigint, client text, for_client text, remove boolean) TO board_agent;
GRANT ALL ON FUNCTION api.project_client(project_id bigint, client text, for_client text, remove boolean) TO board_admin;


--
