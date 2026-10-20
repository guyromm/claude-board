-- Name: doc; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.doc (
    id bigint NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    format text NOT NULL,
    body text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT doc_body_check CHECK ((length(body) <= 2000000)),
    CONSTRAINT doc_format_check CHECK ((format = ANY (ARRAY['org'::text, 'md'::text]))),
    CONSTRAINT doc_slug_check CHECK ((slug ~ '^[a-z0-9][a-z0-9-]{1,79}$'::text)),
    CONSTRAINT doc_title_check CHECK (((length(title) >= 1) AND (length(title) <= 300)))
);


--
