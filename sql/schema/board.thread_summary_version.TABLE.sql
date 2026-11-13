-- Name: thread_summary_version; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.thread_summary_version (
    id bigint NOT NULL,
    thread_id bigint NOT NULL,
    status text,
    needs_human boolean DEFAULT false NOT NULL,
    human_reason text,
    summary text,
    summarized_through bigint,
    summarized_at timestamp with time zone,
    summarized_by text,
    source text DEFAULT 'live'::text NOT NULL
);


--
