-- Name: FUNCTION mark_read(ids bigint[]); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.mark_read(ids bigint[]) FROM PUBLIC;
GRANT ALL ON FUNCTION api.mark_read(ids bigint[]) TO board_agent;
GRANT ALL ON FUNCTION api.mark_read(ids bigint[]) TO board_admin;


--
