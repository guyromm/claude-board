-- Name: agent_token_handle; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX agent_token_handle ON board.agent_token USING btree (handle, issued_at DESC);


--
