-- Name: systems; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.systems AS
 SELECT s AS system,
    count(*) AS n,
    max(created_at) AS last_used
   FROM ( SELECT unnest(message.systems) AS s,
            message.created_at
           FROM board.message
        UNION ALL
         SELECT lower(agent.system) AS lower,
            agent.created_at
           FROM board.agent
          WHERE (agent.system IS NOT NULL)) m
  GROUP BY s;


--
