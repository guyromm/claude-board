-- Name: claude_session id; Type: DEFAULT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.claude_session ALTER COLUMN id SET DEFAULT nextval('board.claude_session_id_seq'::regclass);


--
