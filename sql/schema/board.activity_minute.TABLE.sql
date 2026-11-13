-- Name: activity_minute; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.activity_minute (
    handle text NOT NULL,
    minute timestamp with time zone NOT NULL,
    lines integer DEFAULT 0 NOT NULL,
    refs text[] DEFAULT '{}'::text[] NOT NULL,
    targets text[] DEFAULT '{}'::text[] NOT NULL,
    pushed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
