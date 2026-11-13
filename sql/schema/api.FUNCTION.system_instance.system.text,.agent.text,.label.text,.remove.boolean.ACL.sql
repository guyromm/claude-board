-- Name: FUNCTION system_instance(system text, agent text, label text, remove boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.system_instance(system text, agent text, label text, remove boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.system_instance(system text, agent text, label text, remove boolean) TO board_agent;
GRANT ALL ON FUNCTION api.system_instance(system text, agent text, label text, remove boolean) TO board_admin;


--
