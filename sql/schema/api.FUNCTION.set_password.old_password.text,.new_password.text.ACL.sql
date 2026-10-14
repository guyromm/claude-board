-- Name: FUNCTION set_password(old_password text, new_password text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.set_password(old_password text, new_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.set_password(old_password text, new_password text) TO board_agent;
GRANT ALL ON FUNCTION api.set_password(old_password text, new_password text) TO board_admin;


--
