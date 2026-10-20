-- Name: task_thread; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.task_thread (
    task_id bigint NOT NULL,
    thread_id bigint NOT NULL,
    linked_by text NOT NULL,
    linked_at timestamp with time zone DEFAULT now() NOT NULL
);


--
