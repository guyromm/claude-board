-- Name: project_system(bigint, text, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.project_system(project_id bigint, system text, role text DEFAULT 'uses'::text, remove boolean DEFAULT false) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    IF remove THEN
        DELETE FROM board.project_system ps WHERE ps.project_id = project_system.project_id AND ps.system = project_system.system;
    ELSE
        INSERT INTO board.project_system AS ps (project_id, system, role) VALUES (project_system.project_id, project_system.system, project_system.role)
        ON CONFLICT ON CONSTRAINT project_system_pkey DO UPDATE SET role = EXCLUDED.role;
    END IF;
    RETURN (SELECT row_to_json(x) FROM api.projects x WHERE x.id = project_system.project_id);
END $$;


--
