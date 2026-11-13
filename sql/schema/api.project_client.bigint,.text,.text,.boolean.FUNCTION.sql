-- Name: project_client(bigint, text, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.project_client(project_id bigint, client text, for_client text DEFAULT NULL::text, remove boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.project_client pc WHERE pc.project_id = project_client.project_id AND pc.client = project_client.client;
    ELSE
        INSERT INTO board.project_client AS pc (project_id, client, for_client)
        VALUES (project_client.project_id, project_client.client, nullif(project_client.for_client, ''))
        ON CONFLICT ON CONSTRAINT project_client_pkey DO UPDATE SET for_client = EXCLUDED.for_client;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.projects x WHERE x.id = project_client.project_id);
END $$;


--
