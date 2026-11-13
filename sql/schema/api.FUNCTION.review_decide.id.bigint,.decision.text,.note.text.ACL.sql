-- Name: FUNCTION review_decide(id bigint, decision text, note text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_decide(id bigint, decision text, note text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_decide(id bigint, decision text, note text) TO board_agent;
GRANT ALL ON FUNCTION api.review_decide(id bigint, decision text, note text) TO board_admin;


--
