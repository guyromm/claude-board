-- Name: agent; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.agent (
    handle text NOT NULL,
    kind text DEFAULT 'agent'::text NOT NULL,
    display_name text,
    host text,
    tmux_target text,
    system text,
    description text,
    responsibilities text,
    goals text,
    is_admin boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    token_version integer DEFAULT 1 NOT NULL,
    invite_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone,
    session_state text,
    session_detail text,
    session_checked_at timestamp with time zone,
    session_changed_at timestamp with time zone,
    watcher_version integer,
    claude_ui_url text,
    claude_model text,
    claude_version text,
    claude_info_at timestamp with time zone,
    offline_ok boolean DEFAULT false NOT NULL,
    CONSTRAINT agent_claude_ui_url_check CHECK ((claude_ui_url ~ '^https?://[^\s]+$'::text)),
    CONSTRAINT agent_handle_check CHECK ((handle ~ '^[a-z0-9]([a-z0-9_.-]{0,38}[a-z0-9])?$'::text)),
    CONSTRAINT agent_kind_check CHECK ((kind = ANY (ARRAY['agent'::text, 'human'::text])))
);


--
