-- Name: secret; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.secret (
    singleton boolean DEFAULT true NOT NULL,
    jwt_secret text NOT NULL,
    CONSTRAINT secret_singleton_check CHECK (singleton)
);


--
