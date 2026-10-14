-- Name: message; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.message (
    id bigint NOT NULL,
    sender text NOT NULL,
    subject text NOT NULL,
    body text NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    systems text[] DEFAULT '{}'::text[] NOT NULL,
    reply_to bigint,
    thread_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    tsv tsvector GENERATED ALWAYS AS ((setweight(to_tsvector('english'::regconfig, subject), 'A'::"char") || setweight(to_tsvector('english'::regconfig, body), 'B'::"char"))) STORED,
    broadcast boolean DEFAULT false NOT NULL,
    CONSTRAINT message_body_check CHECK ((length(body) <= 65536)),
    CONSTRAINT message_subject_check CHECK (((length(subject) >= 1) AND (length(subject) <= 300)))
);


--
