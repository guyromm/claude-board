-- Name: project_system; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.project_system (
    project_id bigint NOT NULL,
    system text NOT NULL,
    role text DEFAULT 'uses'::text NOT NULL
);


--
