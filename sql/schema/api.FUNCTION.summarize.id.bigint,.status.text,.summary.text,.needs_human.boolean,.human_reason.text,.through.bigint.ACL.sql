-- Name: FUNCTION summarize(id bigint, status text, summary text, needs_human boolean, human_reason text, through bigint); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.summarize(id bigint, status text, summary text, needs_human boolean, human_reason text, through bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION api.summarize(id bigint, status text, summary text, needs_human boolean, human_reason text, through bigint) TO board_agent;
GRANT ALL ON FUNCTION api.summarize(id bigint, status text, summary text, needs_human boolean, human_reason text, through bigint) TO board_admin;


--
