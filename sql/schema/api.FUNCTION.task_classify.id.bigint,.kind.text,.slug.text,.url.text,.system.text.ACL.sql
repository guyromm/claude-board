-- Name: FUNCTION task_classify(id bigint, kind text, slug text, url text, system text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.task_classify(id bigint, kind text, slug text, url text, system text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.task_classify(id bigint, kind text, slug text, url text, system text) TO board_agent;
GRANT ALL ON FUNCTION api.task_classify(id bigint, kind text, slug text, url text, system text) TO board_admin;


--
