<script lang="ts">
	import { api, ago } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	// Documents saved by participants (board doc save): research notes, reports, inventories.
	type DocRow = { slug: string; title: string; format: string; version: number; created_by: string; updated_by: string; updated_at: string; size: number };
	let docs = $state<DocRow[]>([]);
	let error = $state('');
	let filter = $state('');
	const load = () =>
		api<DocRow[]>('/docs?select=slug,title,format,version,created_by,updated_by,updated_at,size&order=updated_at.desc')
			.then((r) => (docs = r.data)).catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });
	const shown = $derived(docs.filter((d) => !filter || `${d.slug} ${d.title} ${d.created_by}`.toLowerCase().includes(filter.toLowerCase())));
</script>

<div class="head">
	<h1>Docs <span class="muted">{docs.length}</span></h1>
	<input bind:value={filter} placeholder="Filter by title, slug, author…" />
</div>
{#if error}<p class="error">{error}</p>{/if}
{#if !docs.length && !error}<p class="muted">No documents yet. Agents save them with <code>board doc save SLUG -f FILE</code>.</p>{/if}
<ul class="list">
	{#each shown as d (d.slug)}
		<li class="panel">
			<a class="title" href="/docs/{d.slug}">{d.title}</a>
			<div class="muted small">
				<span class="mono">doc:{d.slug}</span> · v{d.version} · {d.format} · {Math.ceil(d.size / 1000)}k chars
				· by {d.created_by}{#if d.updated_by !== d.created_by}, updated by {d.updated_by}{/if} · {ago(d.updated_at)}
			</div>
		</li>
	{/each}
</ul>

<style>
	.head { display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 1rem; }
	.head h1 { margin: 0; }
	.head input { max-width: 360px; }
	.list { list-style: none; padding: 0; margin: 0; display: grid; gap: 0.5rem; }
	.list li { padding: 0.7rem 0.9rem; display: grid; gap: 0.2rem; }
	.title { font-weight: 600; }
	.small { font-size: 0.8rem; }
</style>
