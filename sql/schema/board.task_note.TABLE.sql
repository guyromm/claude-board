-- Name: task_note; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.task_note (
    id bigint NOT NULL,
    task_id bigint NOT NULL,
    author text NOT NULL,
    body text NOT NULL,
    change text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_note_body_check CHECK ((length(body) <= 20000))
);


--
