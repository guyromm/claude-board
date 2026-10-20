-- Name: push_config; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.push_config (
    singleton boolean DEFAULT true NOT NULL,
    vapid_public text NOT NULL,
    CONSTRAINT push_config_singleton_check CHECK (singleton)
);


--
