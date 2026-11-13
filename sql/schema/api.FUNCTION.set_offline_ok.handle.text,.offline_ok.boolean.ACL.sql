-- Name: FUNCTION set_offline_ok(handle text, offline_ok boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.set_offline_ok(handle text, offline_ok boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.set_offline_ok(handle text, offline_ok boolean) TO board_admin;


--
