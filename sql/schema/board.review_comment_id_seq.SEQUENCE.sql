-- Name: review_comment_id_seq; Type: SEQUENCE; Schema: board; Owner: -
--

ALTER TABLE board.review_comment ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME board.review_comment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
