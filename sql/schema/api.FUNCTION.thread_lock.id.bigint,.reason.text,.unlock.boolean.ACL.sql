-- Name: FUNCTION thread_lock(id bigint, reason text, unlock boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.thread_lock(id bigint, reason text, unlock boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.thread_lock(id bigint, reason text, unlock boolean) TO board_agent;
GRANT ALL ON FUNCTION api.thread_lock(id bigint, reason text, unlock boolean) TO board_admin;


--
