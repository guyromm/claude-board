-- Name: FUNCTION review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text, remote text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text, remote text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text, remote text) TO board_agent;
GRANT ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text, remote text) TO board_admin;


--
