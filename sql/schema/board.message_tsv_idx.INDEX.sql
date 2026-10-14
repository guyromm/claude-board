-- Name: message_tsv_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_tsv_idx ON board.message USING gin (tsv);


--
