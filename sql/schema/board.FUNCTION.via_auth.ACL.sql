-- Name: FUNCTION via_auth(); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.via_auth() FROM PUBLIC;
GRANT ALL ON FUNCTION board.via_auth() TO board_anon;
GRANT ALL ON FUNCTION board.via_auth() TO board_agent;
GRANT ALL ON FUNCTION board.via_auth() TO board_admin;


--
