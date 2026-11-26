-- Name: input_request_handle_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX input_request_handle_idx ON board.input_request USING btree (handle, id DESC);


--
