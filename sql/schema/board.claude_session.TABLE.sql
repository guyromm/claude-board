-- Name: claude_session; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.claude_session (
    id bigint NOT NULL,
    who text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    page_loads integer DEFAULT 0 NOT NULL,
    views integer DEFAULT 0 NOT NULL,
    urls jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_url text,
    messages integer DEFAULT 0 NOT NULL,
    user_agent text
);


--
