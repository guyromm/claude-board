-- Name: FUNCTION require_me(); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.require_me() FROM PUBLIC;
GRANT ALL ON FUNCTION board.require_me() TO board_anon;
GRANT ALL ON FUNCTION board.require_me() TO board_agent;
GRANT ALL ON FUNCTION board.require_me() TO board_admin;


--
