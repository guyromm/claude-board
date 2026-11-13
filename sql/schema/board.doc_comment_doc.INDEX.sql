-- Name: doc_comment_doc; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX doc_comment_doc ON board.doc_comment USING btree (doc_id, created_at);


--
