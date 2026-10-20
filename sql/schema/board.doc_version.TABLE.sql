-- Name: doc_version; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.doc_version (
    doc_id bigint NOT NULL,
    version integer NOT NULL,
    title text NOT NULL,
    format text NOT NULL,
    body text NOT NULL,
    saved_by text NOT NULL,
    saved_at timestamp with time zone NOT NULL
);


--
