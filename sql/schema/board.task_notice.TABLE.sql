-- Name: task_notice; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.task_notice (
    id bigint NOT NULL,
    task_id bigint NOT NULL,
    handle text NOT NULL,
    line text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notified_at timestamp with time zone
);


--
