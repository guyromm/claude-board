-- Name: project_client project_client_pkey; Type: CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.project_client
    ADD CONSTRAINT project_client_pkey PRIMARY KEY (project_id, client);


--
