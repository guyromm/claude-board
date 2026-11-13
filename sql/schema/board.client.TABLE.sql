-- Name: client; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.client (
    slug text NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'organisation'::text NOT NULL,
    notes text,
    CONSTRAINT client_kind_check CHECK ((kind = ANY (ARRAY['organisation'::text, 'person'::text]))),
    CONSTRAINT client_slug_check CHECK ((slug ~ '^[a-z0-9][a-z0-9-]*$'::text))
);


--
