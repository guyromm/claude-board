-- Name: login_request_handle_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX login_request_handle_idx ON board.login_request USING btree (handle, id DESC);


--
