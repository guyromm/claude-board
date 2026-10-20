-- Name: doc doc_slug_key; Type: CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc
    ADD CONSTRAINT doc_slug_key UNIQUE (slug);


--
