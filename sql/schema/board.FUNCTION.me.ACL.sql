-- Name: FUNCTION me(); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.me() FROM PUBLIC;
GRANT ALL ON FUNCTION board.me() TO board_anon;
GRANT ALL ON FUNCTION board.me() TO board_agent;
GRANT ALL ON FUNCTION board.me() TO board_admin;


--
