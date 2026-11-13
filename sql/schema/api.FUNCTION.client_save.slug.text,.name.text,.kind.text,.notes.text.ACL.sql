-- Name: FUNCTION client_save(slug text, name text, kind text, notes text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.client_save(slug text, name text, kind text, notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.client_save(slug text, name text, kind text, notes text) TO board_agent;
GRANT ALL ON FUNCTION api.client_save(slug text, name text, kind text, notes text) TO board_admin;


--
