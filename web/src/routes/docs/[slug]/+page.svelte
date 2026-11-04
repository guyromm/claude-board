<script lang="ts">
	import { page } from '$app/state';
	import { api, ago, fmtTime } from '#lib/api.svelte.ts';
	import { renderDoc } from '#lib/render.ts';

	type Doc = { slug: string; title: string; format: 'org' | 'md'; body: string; version: number;
		created_by: string; created_at: string; updated_by: string; updated_at: string };
	type Ver = { version: number; title: string; format: 'org' | 'md'; body: string; saved_by: string; saved_at: string };

	const slug = $derived(page.params.slug ?? '');
	let doc = $state<Doc | null>(null);
	let versions = $state<Ver[]>([]);
	let pick = $state<number | null>(null); // an older version, or null = current
	let raw = $state(false);
	let html = $state('');
	let error = $state('');

	$effect(() => {
		const s = slug;
		error = ''; doc = null; versions = []; pick = null;
		api<Doc[]>(`/docs?slug=eq.${encodeURIComponent(s)}`)
			.then((r) => { if (!r.data.length) throw new Error(`no document "${s}"`); doc = r.data[0]; })
			.catch((e) => (error = e.message));
		api<Ver[]>(`/doc_versions?slug=eq.${encodeURIComponent(s)}&order=version.desc`).then((r) => (versions = r.data)).catch(() => {});
	});
	const shown = $derived(pick && versions.find((v) => v.version === pick) ? versions.find((v) => v.version === pick)! : doc);
	$effect(() => {
		if (!shown) return;
		const { format, body } = shown;
		renderDoc(format, body).then((h) => (html = h)).catch((e) => (html = `<p class="error">render failed: ${String(e.message)}</p>`));
	});

	// Click a table header to sort its rows (asc, then desc). Cells that start with a number sort
	// numerically, everything else (dates are ISO) as text. Delegated, since the doc is {@html}.
	const num = (s: string) => { const m = /^[+-]?\d[\d,]*(\.\d+)?%?$/.exec(s.trim()); return m ? Number(m[0].replace(/[,%]/g, '')) : null; };
	function sortTable(e: MouseEvent) {
		const th = (e.target as HTMLElement).closest('th');
		const table = th?.closest('table');
		const body = table?.tBodies[0];
		if (!th || !table || !body) return;
		const col = Array.from(th.parentElement!.children).indexOf(th);
		const dir = th.dataset.sort === 'asc' ? 'desc' : 'asc';
		table.querySelectorAll('th[data-sort]').forEach((h) => delete (h as HTMLElement).dataset.sort);
		th.dataset.sort = dir;
		const key = (r: HTMLTableRowElement) => r.cells[col]?.textContent ?? '';
		const rows = Array.from(body.rows);
		const allNum = rows.every((r) => key(r).trim() === '' || num(key(r)) !== null);
		rows.sort((a, b) => {
			const x = key(a), y = key(b);
			const c = allNum ? (num(x) ?? -Infinity) - (num(y) ?? -Infinity) : x.localeCompare(y, undefined, { numeric: true, sensitivity: 'base' });
			return dir === 'asc' ? c : -c;
		});
		body.append(...rows);
	}
</script>

<p><a href="/docs">← All docs</a></p>
{#if error}<p class="error">{error}</p>{/if}
{#if doc && shown}
	<header class="meta muted">
		<span class="mono">doc:{doc.slug}</span>
		· {shown.format}
		· <select value={pick ?? ''} onchange={(e) => (pick = Number(e.currentTarget.value) || null)}>
			<option value="">v{doc.version} (current, {fmtTime(doc.updated_at)}, {doc.updated_by})</option>
			{#each versions as v}<option value={v.version}>v{v.version} ({fmtTime(v.saved_at)}, {v.saved_by})</option>{/each}
		</select>
		· created by {doc.created_by} {ago(doc.created_at)}
		· <button class="link" onclick={() => (raw = !raw)}>{raw ? 'rendered' : 'source'}</button>
	</header>
	{#if raw}<pre class="raw">{shown.body}</pre>{:else}<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
		<article class="doc panel" onclick={sortTable}>{@html html}</article>{/if}
{/if}

<style>
	.meta { font-size: 0.8rem; margin-bottom: 0.8rem; display: flex; gap: 0.3rem; align-items: center; flex-wrap: wrap; }
	.meta select { width: auto; font-size: 0.78rem; padding: 0.05rem 0.3rem; }
	.raw { white-space: pre-wrap; font-family: var(--mono); font-size: 0.82rem; }
	.doc { padding: 1rem 1.4rem; line-height: 1.55; overflow-wrap: anywhere; }
	/* the page is full width (wide tables); keep running text at a readable measure */
	.doc :global(:is(p, ul, ol, blockquote, pre, h1, h2, h3, h4)) { max-width: 72rem; }
	.doc :global(h1) { font-size: 1.5rem; margin: 0.4rem 0 0.8rem; }
	.doc :global(h2) { font-size: 1.2rem; margin: 1.4rem 0 0.5rem; border-bottom: 1px solid var(--line); padding-bottom: 0.2rem; }
	.doc :global(h3) { font-size: 1.05rem; margin: 1.1rem 0 0.4rem; }
	.doc :global(h4) { font-size: 0.95rem; margin: 0.9rem 0 0.3rem; }
	.doc :global(table) { border-collapse: collapse; margin: 0.6rem 0; font-size: 0.85rem; display: block; overflow-x: auto; }
	.doc :global(th), .doc :global(td) { border: 1px solid var(--line); padding: 0.25rem 0.55rem; text-align: left; vertical-align: top; }
	.doc :global(th) { cursor: pointer; user-select: none; }
	.doc :global(th[data-sort='asc'])::after { content: ' ▲'; font-size: 0.7em; }
	.doc :global(th[data-sort='desc'])::after { content: ' ▼'; font-size: 0.7em; }
	.doc :global(th) { background: color-mix(in srgb, var(--line) 40%, transparent); }
	.doc :global(pre) { background: color-mix(in srgb, var(--line) 30%, transparent); padding: 0.6rem 0.8rem; border-radius: 6px;
		overflow-x: auto; font-size: 0.8rem; }
	.doc :global(code) { font-family: var(--mono); font-size: 0.85em; }
	.doc :global(ul), .doc :global(ol) { padding-left: 1.4rem; }
	.doc :global(li) { margin: 0.15rem 0; }
	.doc :global(blockquote) { border-left: 3px solid var(--line); margin: 0.6rem 0; padding-left: 0.8rem; color: var(--muted, inherit); }
</style>
