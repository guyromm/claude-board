<script lang="ts">
	// /claude: claude-ui (../claude-ui, its own repo) mounted with the board's PostgREST and session.
	// Only active board admins can use it; the api.claude_* objects enforce that server-side.
	import ClaudePage from '../../../../claude-ui/web/ClaudePage.svelte';
	import { API, session } from '#lib/api.svelte.ts';
	import { boardRenderers } from '#lib/claudeRenderers.ts';
</script>

<ClaudePage
	pgrst={API}
	getToken={() => session.current?.token ?? null}
	isAdmin={() => !!session.current?.is_admin}
	loginUrl="/login?next="
	renderers={boardRenderers}
	title={null}
/>
