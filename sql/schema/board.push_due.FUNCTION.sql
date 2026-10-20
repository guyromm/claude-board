-- Name: push_due(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.push_due() RETURNS TABLE(key text, handle text, tag text, title text, body text, url text, subs json)
    LANGUAGE sql STABLE
    AS $$
    SELECT a.key, h.handle, a.tag, a.title, a.body, a.url,
           json_agg(json_build_object('endpoint', s.endpoint, 'keys', json_build_object('p256dh', s.p256dh, 'auth', s.auth)))
    FROM board.attention a
    JOIN board.agent h ON h.kind = 'human' AND h.active AND (h.handle = a.audience OR (a.audience IS NULL AND h.is_admin))
    JOIN board.push_subscription s ON s.handle = h.handle AND s.created_at < a.at
    WHERE NOT EXISTS (SELECT 1 FROM board.push_sent p WHERE p.key = a.key AND p.handle = h.handle)
    GROUP BY a.key, h.handle, a.tag, a.title, a.body, a.url
    UNION ALL
    SELECT 'test:' || s.endpoint || ':' || extract(epoch FROM s.test_requested_at), s.handle, 'test', 'board notifications are on',
           'This browser will be told when an agent or a decision needs you.', '/',
           json_build_array(json_build_object('endpoint', s.endpoint, 'keys', json_build_object('p256dh', s.p256dh, 'auth', s.auth)))
    FROM board.push_subscription s
    WHERE s.test_requested_at IS NOT NULL
$$;


--
