-- Name: thread_summary; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.thread_summary (
    thread_id bigint NOT NULL,
    status text,
    needs_human boolean DEFAULT false NOT NULL,
    human_reason text,
    summary text,
    summarized_through bigint,
    summarized_at timestamp with time zone,
    summarized_by text,
    prompted_through bigint,
    prompted_at timestamp with time zone,
    CONSTRAINT thread_summary_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text]))),
    CONSTRAINT thread_summary_summary_check CHECK ((length(summary) <= 2000))
);


--
