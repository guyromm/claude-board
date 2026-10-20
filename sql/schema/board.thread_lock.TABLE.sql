-- Name: thread_lock; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.thread_lock (
    thread_id bigint NOT NULL,
    reason text NOT NULL,
    created_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
