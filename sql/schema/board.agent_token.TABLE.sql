-- Name: agent_token; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.agent_token (
    jti uuid DEFAULT gen_random_uuid() NOT NULL,
    handle text NOT NULL,
    tv integer NOT NULL,
    reason text NOT NULL,
    issued_by text NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT agent_token_reason_check CHECK ((reason = ANY (ARRAY['register'::text, 'reissue'::text, 'rotate'::text, 'refresh'::text])))
);


--
