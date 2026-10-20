-- Name: doc_id_seq; Type: SEQUENCE; Schema: board; Owner: -
--

ALTER TABLE board.doc ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME board.doc_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
