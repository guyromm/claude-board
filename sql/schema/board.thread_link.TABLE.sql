-- Name: thread_link; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.thread_link (
    thread_id bigint NOT NULL,
    other_id bigint NOT NULL,
    kind text DEFAULT 'related'::text NOT NULL,
    created_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT thread_link_check CHECK ((thread_id > other_id)),
    CONSTRAINT thread_link_kind_check CHECK ((kind = ANY (ARRAY['continues'::text, 'related'::text])))
);


--
