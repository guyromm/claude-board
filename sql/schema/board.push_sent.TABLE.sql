-- Name: push_sent; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.push_sent (
    key text NOT NULL,
    handle text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL
);


--
