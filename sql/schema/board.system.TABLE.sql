-- Name: system; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.system (
    slug text NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'service'::text NOT NULL,
    owner text,
    repo text,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT system_slug_check CHECK ((slug ~ '^[a-z0-9][a-z0-9-]*$'::text))
);


--
