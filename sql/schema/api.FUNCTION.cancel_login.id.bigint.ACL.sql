-- Name: FUNCTION cancel_login(id bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.cancel_login(id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.cancel_login(id bigint) TO board_admin;


--
