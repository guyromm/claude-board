-- Name: doc_comment_id_seq; Type: SEQUENCE; Schema: board; Owner: -
--

ALTER TABLE board.doc_comment ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME board.doc_comment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
