-- Name: review_rev; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.review_rev (
    review_id bigint NOT NULL,
    rev integer NOT NULL,
    head_sha text,
    base_sha text,
    diff text NOT NULL,
    files integer DEFAULT 0 NOT NULL,
    adds integer DEFAULT 0 NOT NULL,
    dels integer DEFAULT 0 NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT review_rev_diff_check CHECK ((length(diff) <= 5000000))
);


--
