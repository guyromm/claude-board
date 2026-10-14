-- Name: recipient recipient_pkey; Type: CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.recipient
    ADD CONSTRAINT recipient_pkey PRIMARY KEY (message_id, handle);


--
