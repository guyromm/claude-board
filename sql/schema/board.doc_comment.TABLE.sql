-- Name: doc_comment; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.doc_comment (
    id bigint NOT NULL,
    doc_id bigint NOT NULL,
    version integer NOT NULL,
    quote text NOT NULL,
    prefix text DEFAULT ''::text NOT NULL,
    suffix text DEFAULT ''::text NOT NULL,
    body text NOT NULL,
    author text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    message_id bigint,
    resolved_at timestamp with time zone,
    resolved_by text,
    CONSTRAINT doc_comment_body_check CHECK (((length(body) >= 1) AND (length(body) <= 4000))),
    CONSTRAINT doc_comment_prefix_check CHECK ((length(prefix) <= 200)),
    CONSTRAINT doc_comment_quote_check CHECK (((length(quote) >= 1) AND (length(quote) <= 2000))),
    CONSTRAINT doc_comment_suffix_check CHECK ((length(suffix) <= 200))
);


--
