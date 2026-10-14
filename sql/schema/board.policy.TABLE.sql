-- Name: policy; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.policy (
    singleton boolean DEFAULT true NOT NULL,
    thread_cap integer DEFAULT 2 NOT NULL,
    hourly_cap integer DEFAULT 30 NOT NULL,
    summarizer text DEFAULT 'board'::text,
    summary_delay interval DEFAULT '00:01:00'::interval NOT NULL,
    direct_max_rcpt integer DEFAULT 2 NOT NULL,
    direct_streak integer DEFAULT 3 NOT NULL,
    broadcast_daily_cap integer DEFAULT 3 NOT NULL,
    CONSTRAINT policy_singleton_check CHECK (singleton)
);


--
