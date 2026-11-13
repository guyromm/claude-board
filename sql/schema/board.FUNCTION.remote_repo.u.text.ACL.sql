-- Name: FUNCTION remote_repo(u text); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.remote_repo(u text) FROM PUBLIC;
GRANT ALL ON FUNCTION board.remote_repo(u text) TO board_agent;
GRANT ALL ON FUNCTION board.remote_repo(u text) TO board_admin;


--
