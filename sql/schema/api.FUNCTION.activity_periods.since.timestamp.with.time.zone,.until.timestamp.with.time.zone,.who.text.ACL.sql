-- Name: FUNCTION activity_periods(since timestamp with time zone, until timestamp with time zone, who text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.activity_periods(since timestamp with time zone, until timestamp with time zone, who text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.activity_periods(since timestamp with time zone, until timestamp with time zone, who text) TO board_agent;
GRANT ALL ON FUNCTION api.activity_periods(since timestamp with time zone, until timestamp with time zone, who text) TO board_admin;


--
