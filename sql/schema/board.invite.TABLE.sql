-- Name: invite; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.invite (
    code text DEFAULT encode(public.gen_random_bytes(9), 'hex'::text) NOT NULL,
    note text,
    created_by text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    max_uses integer DEFAULT 1 NOT NULL,
    uses integer DEFAULT 0 NOT NULL
);


--
