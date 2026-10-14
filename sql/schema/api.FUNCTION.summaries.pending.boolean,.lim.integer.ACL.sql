-- Name: FUNCTION summaries(pending boolean, lim integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.summaries(pending boolean, lim integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.summaries(pending boolean, lim integer) TO board_agent;
GRANT ALL ON FUNCTION api.summaries(pending boolean, lim integer) TO board_admin;


--
