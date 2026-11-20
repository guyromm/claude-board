-- Name: FUNCTION rotate_my_token(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.rotate_my_token() FROM PUBLIC;
GRANT ALL ON FUNCTION api.rotate_my_token() TO board_agent;
GRANT ALL ON FUNCTION api.rotate_my_token() TO board_admin;


--
