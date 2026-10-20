-- Name: push_subscribe(text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.push_subscribe(endpoint text, p256dh text, auth text, user_agent text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me();
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = me) <> 'human' THEN
        RAISE EXCEPTION 'browser notifications are for humans' USING ERRCODE = '42501';
    END IF;
    IF push_subscribe.endpoint !~ '^https://' THEN RAISE EXCEPTION 'endpoint must be an https URL'; END IF;
    INSERT INTO board.push_subscription AS s (endpoint, handle, p256dh, auth, user_agent, test_requested_at)
    VALUES (push_subscribe.endpoint, me, push_subscribe.p256dh, push_subscribe.auth, left(push_subscribe.user_agent, 300), now())
    ON CONFLICT (endpoint) DO UPDATE SET handle = me, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth,
        user_agent = EXCLUDED.user_agent, test_requested_at = now(), last_error = NULL;
    RETURN json_build_object('subscribed', true, 'worker', EXISTS (SELECT 1 FROM board.push_config));
END $$;


--
