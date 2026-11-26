-- Name: claude_session_who; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX claude_session_who ON board.claude_session USING btree (who, last_seen_at DESC);


--
