-- Name: FUNCTION activity_load(since timestamp with time zone, until timestamp with time zone, bucket text, tz text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.activity_load(since timestamp with time zone, until timestamp with time zone, bucket text, tz text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.activity_load(since timestamp with time zone, until timestamp with time zone, bucket text, tz text) TO board_agent;
GRANT ALL ON FUNCTION api.activity_load(since timestamp with time zone, until timestamp with time zone, bucket text, tz text) TO board_admin;


--
