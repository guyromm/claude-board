-- Name: task_thread task_thread_pkey; Type: CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.task_thread
    ADD CONSTRAINT task_thread_pkey PRIMARY KEY (task_id, thread_id);


--
