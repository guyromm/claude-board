-- Name: FUNCTION review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text) TO board_agent;
GRANT ALL ON FUNCTION api.review_submit(repo text, branch text, diff text, title text, base text, description text, head_sha text, base_sha text, compare_url text, task text, note text) TO board_admin;


--
