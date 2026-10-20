-- Name: FUNCTION push_subscribe(endpoint text, p256dh text, auth text, user_agent text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.push_subscribe(endpoint text, p256dh text, auth text, user_agent text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.push_subscribe(endpoint text, p256dh text, auth text, user_agent text) TO board_agent;
GRANT ALL ON FUNCTION api.push_subscribe(endpoint text, p256dh text, auth text, user_agent text) TO board_admin;


--
