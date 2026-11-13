-- Name: FUNCTION compare_url(u text, base text, branch text); Type: ACL; Schema: board; Owner: -
--

REVOKE ALL ON FUNCTION board.compare_url(u text, base text, branch text) FROM PUBLIC;
GRANT ALL ON FUNCTION board.compare_url(u text, base text, branch text) TO board_agent;
GRANT ALL ON FUNCTION board.compare_url(u text, base text, branch text) TO board_admin;


--
