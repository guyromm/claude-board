<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, ago, fmtTime } from '#lib/api.svelte.ts';
	import { renderDoc } from '#lib/render.ts';
	import { head } from '#lib/title.svelte.ts';
	import { tick } from 'svelte';
	import { highlight, context, idsAt, norm } from '#lib/anchor.ts';

	type Doc = { slug: string; title: string; format: 'org' | 'md'; body: string; version: number;
		created_by: string; created_at: string; updated_by: string; updated_at: string };
	type Ver = { version: number; title: string; format: 'org' | 'md'; body: string; saved_by: string; saved_at: string };

	const slug = $derived(page.params.slug ?? '');
	let doc = $state<Doc | null>(null);
	$effect(() => { if (doc) head.title = `${doc.title || doc.slug} (doc:${doc.slug})`; });
	let versions = $state<Ver[]>([]);
	// the shown version lives in the URL (?v=N, guy 11-15) so a link opens the same revision; none = current
	const pick = $derived.by(() => {
		const v = Number(page.url.searchParams.get('v'));
		return Number.isInteger(v) && v > 0 && (!doc || v !== doc.version) ? v : null;
	});
	function choose(v: number | null) {
		const u = new URL(page.url.href);
		if (v) u.searchParams.set('v', String(v)); else u.searchParams.delete('v');
		goto(u.pathname + u.search + u.hash, { reset: false });
	}
	let raw = $state(false);
	let html = $state('');
	let error = $state('');

	// comments on a selected passage (guy, 11-13): select text -> "Comment"; hover a highlight to read
	type Cmt = { id: number; slug: string; version: number; quote: string; prefix: string; suffix: string; body: string;
		author: string; created_at: string; resolved_at: string | null; resolved_by: string | null };
	let comments = $state<Cmt[]>([]);
	let article = $state<HTMLElement | null>(null);
	let placed = $state<Set<number>>(new Set()); // comments anchored in the shown text
	let sel = $state<{ quote: string; prefix: string; suffix: string; x: number; y: number } | null>(null);
	let composing = $state(false);
	let draft = $state('');
	let saving = $state(false);
	let cerr = $state('');
	let hover = $state<{ ids: number[]; x: number; y: number; pinned: boolean } | null>(null);
	let showResolved = $state(false);
	const loadComments = (s: string) =>
		api<Cmt[]>(`/doc_comments?slug=eq.${encodeURIComponent(s)}&order=created_at`).then((r) => (comments = r.data)).catch(() => {});
	const open = $derived(comments.filter((c) => !c.resolved_at));
	const byId = (id: number) => comments.find((c) => c.id === id);

	$effect(() => {
		const s = slug;
		error = ''; doc = null; versions = [];
		api<Doc[]>(`/docs?slug=eq.${encodeURIComponent(s)}`)
			.then((r) => { if (!r.data.length) throw new Error(`no document "${s}"`); doc = r.data[0]; })
			.catch((e) => (error = e.message));
		loadVersions(s);
		comments = []; sel = null; composing = false; hover = null;
		loadComments(s);
	});
	const loadVersions = (s: string) =>
		api<Ver[]>(`/doc_versions?slug=eq.${encodeURIComponent(s)}&order=version.desc`).then((r) => (versions = r.data)).catch(() => {});
	// a new revision saved while the page is open (guy, 11-15): poll the version number; the current view
	// switches to it, an older pinned version (?v=N) stays put and only gains the new entry in the list
	$effect(() => {
		const s = slug;
		const check = () => {
			if (document.hidden || !doc || doc.slug !== s || composing) return;
			api<Doc[]>(`/docs?slug=eq.${encodeURIComponent(s)}&select=version`).then((r) => {
				const v = r.data[0]?.version;
				if (!v || !doc || doc.slug !== s || v === doc.version) return;
				api<Doc[]>(`/docs?slug=eq.${encodeURIComponent(s)}`).then((d) => { if (d.data.length) doc = d.data[0]; });
				loadVersions(s); loadComments(s);
			}).catch(() => {});
		};
		const t = setInterval(check, 30_000);
		document.addEventListener('visibilitychange', check);
		return () => { clearInterval(t); document.removeEventListener('visibilitychange', check); };
	});
	// PDF (guy, 11-15): the browser's own print-to-PDF of the rendered doc. Vector text, RTL/Hebrew and links
	// stay right, and no server-side renderer runs on posted HTML. The title names the saved file.
	async function savePdf() {
		if (!doc) return;
		raw = false; hover = null; sel = null; composing = false;
		await tick();
		const was = document.title;
		document.title = `${doc.slug}-v${pick ?? doc.version}`;
		const restore = () => { document.title = was; window.removeEventListener('afterprint', restore); };
		window.addEventListener('afterprint', restore);
		window.print();
	}
	const shown = $derived(pick && versions.find((v) => v.version === pick) ? versions.find((v) => v.version === pick)! : doc);
	$effect(() => {
		if (!shown) return;
		const { format, body } = shown;
		renderDoc(format, body).then((h) => (html = h)).catch((e) => (html = `<p class="error">render failed: ${String(e.message)}</p>`));
	});
	// render the HTML ourselves (not {@html}) so the comment highlights can be re-applied on a clean copy
	$effect(() => {
		const el = article, h = html, cs = open;
		if (!el) return;
		el.innerHTML = h;
		const got = new Set<number>();
		for (const c of cs) if (highlight(el, c.quote, c.prefix, c.id)) got.add(c.id);
		placed = got;
		const m = /^#comment-(\d+)$/.exec(location.hash);
		if (m) tick().then(() => document.getElementById(`comment-${m[1]}`)?.scrollIntoView({ block: 'center' }));
	});

	function onSelect() {
		setTimeout(() => {
			const s = window.getSelection();
			if (!article || !s || s.isCollapsed || !s.rangeCount) { if (!composing) sel = null; return; }
			const r = s.getRangeAt(0);
			if (!article.contains(r.commonAncestorContainer)) { if (!composing) sel = null; return; }
			const quote = norm(r.toString()).trim();
			if (!quote) return;
			const { prefix, suffix } = context(article, r);
			const box = r.getBoundingClientRect();
			sel = { quote: quote.slice(0, 2000), prefix, suffix, x: Math.min(box.left + box.width / 2, innerWidth - 60), y: box.bottom };
			composing = false; cerr = '';
		}, 0);
	}
	async function saveComment() {
		if (!sel || !doc || !draft.trim()) return;
		saving = true; cerr = '';
		try {
			const r = await api<{ id: number }>('/rpc/doc_comment', { body: { slug: doc.slug, quote: sel.quote, body: draft.trim(),
				version: shown?.version ?? doc.version, prefix: sel.prefix, suffix: sel.suffix } });
			draft = ''; sel = null; composing = false; window.getSelection()?.removeAllRanges();
			await loadComments(doc.slug);
			if (r.data?.id) history.replaceState(null, '', `#comment-${r.data.id}`);
		} catch (e) { cerr = (e as Error).message; } finally { saving = false; }
	}
	async function resolve(c: Cmt, yes = true) {
		try { await api('/rpc/doc_comment_resolve', { body: { id: c.id, resolved: yes } }); await loadComments(c.slug); hover = null; }
		catch (e) { alert((e as Error).message); }
	}
	function onOver(e: MouseEvent) {
		if (hover?.pinned) return;
		const ids = idsAt(e.target as Element);
		if (!ids.length) { hover = null; return; }
		const m = (e.target as Element).closest('mark.cmt')!.getBoundingClientRect();
		hover = { ids, x: Math.min(m.left, innerWidth - 340), y: m.bottom + 4, pinned: false };
	}
	function onArticleClick(e: MouseEvent) {
		sortTable(e);
		const ids = idsAt(e.target as Element);
		if (ids.length && window.getSelection()?.isCollapsed) {
			const m = (e.target as Element).closest('mark.cmt')!.getBoundingClientRect();
			hover = { ids, x: Math.min(m.left, innerWidth - 340), y: m.bottom + 4, pinned: true };
		}
	}
	function flash(id: number) {
		const m = article?.querySelector(`mark.cmt[data-cid="${id}"]`);
		if (!m) return;
		m.scrollIntoView({ block: 'center', behavior: 'smooth' });
		m.classList.add('flash'); setTimeout(() => m.classList.remove('flash'), 1600);
	}

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
		· <select value={pick ?? ''} onchange={(e) => choose(Number(e.currentTarget.value) || null)}>
			<option value="">v{doc.version} (current, {fmtTime(doc.updated_at)}, {doc.updated_by})</option>
			{#each versions as v}<option value={v.version}>v{v.version} ({fmtTime(v.saved_at)}, {v.saved_by})</option>{/each}
		</select>
		{#if versions.length}· <a href="/docs/{doc.slug}/diff?{pick ? `to=${pick}` : `to=${doc.version}`}">changes</a>{/if}
		· created by {doc.created_by} {ago(doc.created_at)}
		· <button class="link" onclick={() => (raw = !raw)}>{raw ? 'rendered' : 'source'}</button>
		· <button class="link" onclick={savePdf} title="Print view: choose 'Save as PDF' as the destination">PDF</button>
		{#if open.length}· <a href="#comments">{open.length} comment{open.length === 1 ? '' : 's'}</a>{/if}
	</header>
	<div class="print-head">{shown.title || doc.slug} <span>doc:{doc.slug} · v{pick ?? doc.version} · {fmtTime(pick ? (versions.find((v) => v.version === pick)?.saved_at ?? doc.updated_at) : doc.updated_at)}</span></div>
	{#if raw}<pre class="raw">{shown.body}</pre>{:else}<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions, a11y_mouse_events_have_key_events -->
		<article class="doc panel" bind:this={article} onclick={onArticleClick} onmouseup={onSelect} ontouchend={onSelect}
			onmouseover={onOver} onmouseleave={() => { if (!hover?.pinned) hover = null; }}></article>
		<p class="hint muted">Select any passage to comment on it. The doc's author gets a board message.</p>{/if}

	{#if sel && !raw}
		<div class="cbox" style="left:{Math.max(8, Math.min(sel.x - 160, innerWidth - 336))}px; top:{sel.y + 6}px">
			{#if !composing}
				<button onmousedown={(e) => e.preventDefault()} onclick={() => (composing = true)}>💬 Comment</button>
			{:else}
				<blockquote>{sel.quote.length > 220 ? sel.quote.slice(0, 220) + '…' : sel.quote}</blockquote>
				<!-- svelte-ignore a11y_autofocus -->
				<textarea bind:value={draft} rows="4" placeholder="Your comment (Ctrl+Enter saves)" autofocus
					onkeydown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) saveComment(); if (e.key === 'Escape') { sel = null; composing = false; } }}></textarea>
				{#if cerr}<p class="error">{cerr}</p>{/if}
				<div class="row">
					<button onclick={saveComment} disabled={saving || !draft.trim()}>{saving ? 'Saving…' : 'Save'}</button>
					<button class="link" onclick={() => { sel = null; composing = false; }}>cancel</button>
				</div>
			{/if}
		</div>
	{/if}

	{#if hover}
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div class="pop" style="left:{Math.max(8, hover.x)}px; top:{hover.y}px" onmouseleave={() => { if (!hover?.pinned) hover = null; }}>
			{#each hover.ids as id}{@const c = byId(id)}{#if c}
				<div class="pc">
					<div class="who muted">{c.author} · {ago(c.created_at)}{c.version !== doc.version ? ` · on v${c.version}` : ''}</div>
					<div class="body">{c.body}</div>
					<div class="acts"><a href="#comment-{c.id}">link</a> · <button class="link" onclick={() => resolve(c)}>resolve</button></div>
				</div>
			{/if}{/each}
			{#if hover.pinned}<button class="link close" onclick={() => (hover = null)}>close</button>{/if}
		</div>
	{/if}

	{#if comments.length}
		<section id="comments" class="clist">
			<h2>Comments <span class="muted">({open.length} open{comments.length > open.length ? `, ${comments.length - open.length} resolved` : ''})</span>
				{#if comments.length > open.length}<button class="link" onclick={() => (showResolved = !showResolved)}>{showResolved ? 'hide' : 'show'} resolved</button>{/if}</h2>
			{#each comments.filter((c) => showResolved || !c.resolved_at) as c (c.id)}
				<div class="ci" class:resolved={c.resolved_at} id="comment-{c.id}">
					<blockquote>{#if placed.has(c.id)}<button class="link q" onclick={() => flash(c.id)}>{c.quote.length > 200 ? c.quote.slice(0, 200) + '…' : c.quote}</button>{:else}{c.quote.length > 200 ? c.quote.slice(0, 200) + '…' : c.quote}{/if}</blockquote>
					<div class="body">{c.body}</div>
					<div class="who muted">
						{c.author} · {fmtTime(c.created_at)} · on v{c.version}
						{#if !c.resolved_at && !placed.has(c.id) && !raw} · <em>passage not in this version</em>{/if}
						{#if c.resolved_at} · resolved by {c.resolved_by} <button class="link" onclick={() => resolve(c, false)}>reopen</button>
						{:else} · <button class="link" onclick={() => resolve(c)}>resolve</button>{/if}
					</div>
				</div>
			{/each}
		</section>
	{/if}
{/if}

<style>
	.meta { font-size: 0.8rem; margin-bottom: 0.8rem; display: flex; gap: 0.3rem; align-items: center; flex-wrap: wrap; }
	.meta select { width: auto; font-size: 0.78rem; padding: 0.05rem 0.3rem; }
	.hint { font-size: 0.75rem; margin: 0.3rem 0 0; }
	.doc :global(mark.cmt) { background: color-mix(in srgb, #f5c542 35%, transparent); color: inherit; border-bottom: 2px solid #e0a800;
		cursor: pointer; border-radius: 2px; }
	.doc :global(mark.cmt mark.cmt) { background: color-mix(in srgb, #f5c542 60%, transparent); }
	.doc :global(mark.cmt.flash) { outline: 2px solid #e0a800; }
	.cbox, .pop { position: fixed; z-index: 50; background: var(--bg, #fff); border: 1px solid var(--line); border-radius: 8px;
		box-shadow: 0 6px 24px rgba(0,0,0,0.18); padding: 0.5rem; width: min(320px, calc(100vw - 16px)); font-size: 0.85rem; }
	.cbox:has(> button:only-child) { width: auto; padding: 0.2rem; }
	.cbox textarea { width: 100%; box-sizing: border-box; font: inherit; }
	.cbox blockquote, .clist blockquote { margin: 0 0 0.35rem; padding-left: 0.5rem; border-left: 3px solid #e0a800; font-size: 0.8rem;
		max-height: 6rem; overflow: auto; }
	.cbox .row { display: flex; gap: 0.6rem; align-items: center; margin-top: 0.3rem; }
	.pop { max-height: 50vh; overflow: auto; }
	.pc + .pc { border-top: 1px solid var(--line); margin-top: 0.4rem; padding-top: 0.4rem; }
	.pc .body, .ci .body { white-space: pre-wrap; overflow-wrap: anywhere; }
	.who { font-size: 0.75rem; }
	.acts { font-size: 0.75rem; margin-top: 0.2rem; }
	.close { font-size: 0.75rem; margin-top: 0.3rem; }
	.clist { margin-top: 1.4rem; font-size: 0.88rem; }
	.clist h2 { font-size: 1rem; display: flex; gap: 0.6rem; align-items: baseline; }
	.ci { padding: 0.5rem 0; border-top: 1px solid var(--line); }
	.ci.resolved { opacity: 0.6; }
	.ci:target { background: color-mix(in srgb, #f5c542 18%, transparent); }
	.q { text-align: left; font: inherit; }
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
	.print-head { display: none; }
	/* print / Save as PDF: only the title line and the doc itself, black on white, tables unclipped */
	@media print {
		@page { margin: 14mm 12mm; }
		:global(html), :global(body) { background: #fff !important; padding: 0 !important; margin: 0 !important; }
		/* the site bar, alerts and the chat dock (siblings of <main>), and everything on this page but the doc */
		:global(body > div > :not(main)), :global(main > :not(.print-head, .doc, .raw)) { display: none !important; }
		:global(main) { max-width: none !important; width: auto !important; padding: 0 !important; margin: 0 !important; }
		.print-head { display: block; font-size: 1.1rem; font-weight: 600; color: #000; border-bottom: 1px solid #999;
			padding-bottom: 0.3rem; margin-bottom: 0.8rem; }
		.print-head span { display: block; font-size: 0.75rem; font-weight: 400; color: #555; }
		.doc, .raw { border: 0 !important; box-shadow: none !important; background: #fff !important; color: #000 !important;
			padding: 0 !important; margin: 0 !important; }
		.doc :global(*) { color: #000 !important; }
		.doc :global(a) { color: #1a4fb4 !important; text-decoration: underline; }
		.doc :global(mark.cmt) { background: none !important; border: 0 !important; }
		.doc :global(table) { display: table; overflow: visible; font-size: 0.75rem; }
		.doc :global(th), .doc :global(td) { border: 1px solid #999 !important; }
		.doc :global(th) { background: #eee !important; }
		.doc :global(tr), .doc :global(pre), .doc :global(blockquote) { break-inside: avoid; }
		.doc :global(:is(h1, h2, h3, h4)) { break-after: avoid; }
		.doc :global(th)::after { content: none !important; }
		.doc :global(pre) { white-space: pre-wrap; background: #f3f3f3 !important; }
		.doc :global(:is(p, ul, ol, blockquote, pre, h1, h2, h3, h4)) { max-width: none; }
	}
</style>
