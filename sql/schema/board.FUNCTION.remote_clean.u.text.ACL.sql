-- Name: FUNCTION remote_clean(u text); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.remote_clean(u text) FROM PUBLIC;
GRANT ALL ON FUNCTION board.remote_clean(u text) TO board_agent;
GRANT ALL ON FUNCTION board.remote_clean(u text) TO board_admin;


--
