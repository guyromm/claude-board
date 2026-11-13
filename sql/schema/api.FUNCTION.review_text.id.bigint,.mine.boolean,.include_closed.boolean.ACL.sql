-- Name: FUNCTION review_text(id bigint, mine boolean, include_closed boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.review_text(id bigint, mine boolean, include_closed boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.review_text(id bigint, mine boolean, include_closed boolean) TO board_agent;
GRANT ALL ON FUNCTION api.review_text(id bigint, mine boolean, include_closed boolean) TO board_admin;


--
