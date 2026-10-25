-- Name: FUNCTION is_admin(); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.is_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION board.is_admin() TO board_anon;
GRANT ALL ON FUNCTION board.is_admin() TO board_agent;
GRANT ALL ON FUNCTION board.is_admin() TO board_admin;


--
