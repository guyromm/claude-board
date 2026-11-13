-- Name: review_comment; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.review_comment (
    id bigint NOT NULL,
    review_id bigint NOT NULL,
    rev integer NOT NULL,
    path text DEFAULT ''::text NOT NULL,
    side text DEFAULT 'new'::text NOT NULL,
    line integer,
    quote text DEFAULT ''::text NOT NULL,
    body text NOT NULL,
    author text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    message_id bigint,
    resolved_at timestamp with time zone,
    resolved_by text,
    CONSTRAINT review_comment_body_check CHECK (((length(body) >= 1) AND (length(body) <= 8000))),
    CONSTRAINT review_comment_quote_check CHECK ((length(quote) <= 4000)),
    CONSTRAINT review_comment_side_check CHECK ((side = ANY (ARRAY['old'::text, 'new'::text])))
);


--
