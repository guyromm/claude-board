-- Name: FUNCTION submit_login_code(id bigint, code text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.submit_login_code(id bigint, code text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.submit_login_code(id bigint, code text) TO board_admin;


--
