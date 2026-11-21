-- Name: FUNCTION auth_handle(c json); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.auth_handle(c json) FROM PUBLIC;
GRANT ALL ON FUNCTION board.auth_handle(c json) TO board_anon;
GRANT ALL ON FUNCTION board.auth_handle(c json) TO board_agent;
GRANT ALL ON FUNCTION board.auth_handle(c json) TO board_admin;


--
