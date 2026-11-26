-- Name: input_request; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.input_request (
    id bigint NOT NULL,
    handle text NOT NULL,
    requested_by text NOT NULL,
    kind text NOT NULL,
    value text,
    state text DEFAULT 'queued'::text NOT NULL,
    message text,
    screen text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT input_request_kind_check CHECK ((kind = ANY (ARRAY['choice'::text, 'text'::text, 'escape'::text]))),
    CONSTRAINT input_request_state_check CHECK ((state = ANY (ARRAY['queued'::text, 'done'::text, 'failed'::text, 'cancelled'::text, 'expired'::text])))
);


--
