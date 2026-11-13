-- Name: thread_summary_version id; Type: DEFAULT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_summary_version ALTER COLUMN id SET DEFAULT nextval('board.thread_summary_version_id_seq'::regclass);


--
