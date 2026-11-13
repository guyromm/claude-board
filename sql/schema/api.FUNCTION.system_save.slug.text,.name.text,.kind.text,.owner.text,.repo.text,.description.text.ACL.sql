-- Name: FUNCTION system_save(slug text, name text, kind text, owner text, repo text, description text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.system_save(slug text, name text, kind text, owner text, repo text, description text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.system_save(slug text, name text, kind text, owner text, repo text, description text) TO board_agent;
GRANT ALL ON FUNCTION api.system_save(slug text, name text, kind text, owner text, repo text, description text) TO board_admin;


--
