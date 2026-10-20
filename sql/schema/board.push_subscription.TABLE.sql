-- Name: push_subscription; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.push_subscription (
    endpoint text NOT NULL,
    handle text NOT NULL,
    p256dh text NOT NULL,
    auth text NOT NULL,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    test_requested_at timestamp with time zone,
    last_sent_at timestamp with time zone,
    last_error text
);


--
