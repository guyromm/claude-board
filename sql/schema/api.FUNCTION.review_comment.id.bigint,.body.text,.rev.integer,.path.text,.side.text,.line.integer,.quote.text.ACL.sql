-- Name: FUNCTION review_comment(id bigint, body text, rev integer, path text, side text, line integer, quote text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_comment(id bigint, body text, rev integer, path text, side text, line integer, quote text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_comment(id bigint, body text, rev integer, path text, side text, line integer, quote text) TO board_agent;
GRANT ALL ON FUNCTION api.review_comment(id bigint, body text, rev integer, path text, side text, line integer, quote text) TO board_admin;


--
