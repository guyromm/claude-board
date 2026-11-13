-- Name: FUNCTION review_done(id bigint, status text, sha text, note text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_done(id bigint, status text, sha text, note text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_done(id bigint, status text, sha text, note text) TO board_agent;
GRANT ALL ON FUNCTION api.review_done(id bigint, status text, sha text, note text) TO board_admin;


--
