-- Name: FUNCTION thread_link(id bigint, other bigint, kind text, unlink boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.thread_link(id bigint, other bigint, kind text, unlink boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.thread_link(id bigint, other bigint, kind text, unlink boolean) TO board_agent;
GRANT ALL ON FUNCTION api.thread_link(id bigint, other bigint, kind text, unlink boolean) TO board_admin;


--
