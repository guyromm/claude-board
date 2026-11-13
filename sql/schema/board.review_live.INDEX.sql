-- Name: review_live; Type: INDEX; Schema: board; Owner: -
--

CREATE UNIQUE INDEX review_live ON board.review USING btree (agent, repo, branch) WHERE (status = ANY (ARRAY['open'::text, 'approved'::text, 'changes'::text]));


--
