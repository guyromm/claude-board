-- Name: FUNCTION set_active(handle text, active boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.set_active(handle text, active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.set_active(handle text, active boolean) TO board_admin;


--
