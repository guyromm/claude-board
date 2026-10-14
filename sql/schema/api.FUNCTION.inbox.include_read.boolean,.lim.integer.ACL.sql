-- Name: FUNCTION inbox(include_read boolean, lim integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.inbox(include_read boolean, lim integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.inbox(include_read boolean, lim integer) TO board_agent;
GRANT ALL ON FUNCTION api.inbox(include_read boolean, lim integer) TO board_admin;


--
