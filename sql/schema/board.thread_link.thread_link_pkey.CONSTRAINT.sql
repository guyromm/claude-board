-- Name: thread_link thread_link_pkey; Type: CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_link
    ADD CONSTRAINT thread_link_pkey PRIMARY KEY (thread_id, other_id);


--
