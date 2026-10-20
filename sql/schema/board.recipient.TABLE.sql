-- Name: recipient; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.recipient (
    message_id bigint NOT NULL,
    handle text NOT NULL,
    notified_at timestamp with time zone,
    read_at timestamp with time zone,
    deliver_at timestamp with time zone
);


--
