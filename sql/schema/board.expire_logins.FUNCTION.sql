-- Name: expire_logins(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.expire_logins() RETURNS void
    LANGUAGE sql
    AS $$
    UPDATE board.login_request SET state = 'expired', code = NULL, updated_at = now(),
           message = coalesce(message || ' -- ', '') || 'expired: no progress for 20 minutes'
    WHERE state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
      AND updated_at < now() - interval '20 minutes'
$$;


--
