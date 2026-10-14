-- Name: login_request; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.login_request (
    id bigint NOT NULL,
    handle text NOT NULL,
    requested_by text NOT NULL,
    state text DEFAULT 'requested'::text NOT NULL,
    url text,
    code text,
    message text,
    pane_tail text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT login_request_state_check CHECK ((state = ANY (ARRAY['requested'::text, 'started'::text, 'url_ready'::text, 'code_submitted'::text, 'code_entered'::text, 'code_rejected'::text, 'succeeded'::text, 'failed'::text, 'expired'::text, 'cancelled'::text])))
);


--
