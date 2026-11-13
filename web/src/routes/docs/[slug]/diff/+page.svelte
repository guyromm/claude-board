<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, fmtTime } from '#lib/api.svelte.ts';
	import { diffLines, hunks, stats, type Row, type Hunk } from '#lib/diff.ts';
	import { quoteLines, stripLine, norm } from '#lib/anchor.ts';
	import { ago } from '#lib/api.svelte.ts';

	type Doc = { slug: string; title: string; format: string; body: string; version: number; updated_by: string; updated_at: string };
	type Ver = { version: number; title: string; format: string; body: string; saved_by: string; saved_at: string };
	type V = { version: number; title: string; format: string; body: string; by: string; at: string };

	const slug = $derived(page.params.slug ?? '');
	let all = $state<V[]>([]); // every version, newest first (current included)
	let error = $state('');
	let mode = $state<'unified' | 'split'>('unified');
	let opened = $state<Set<number>>(new Set()); // expanded folded runs (hunk index)

	try { const m = localStorage.getItem('docdiff.mode'); if (m === 'split' || m === 'unified') mode = m; } catch {}
	const setMode = (m: 'unified' | 'split') => { mode = m; try { localStorage.setItem('docdiff.mode', m); } catch {} };

	$effect(() => {
		const s = slug;
		error = ''; all = [];
		Promise.all([
			api<Doc[]>(`/docs?slug=eq.${encodeURIComponent(s)}`),
			api<Ver[]>(`/doc_versions?slug=eq.${encodeURIComponent(s)}&order=version.desc`),
		]).then(([d, v]) => {
			if (!d.data.length) throw new Error(`no document "${s}"`);
			const cur = d.data[0];
			all = [{ version: cur.version, title: cur.title, format: cur.format, body: cur.body, by: cur.updated_by, at: cur.updated_at },
				...v.data.filter((x) => x.version !== cur.version)
					.map((x) => ({ version: x.version, title: x.title, format: x.format, body: x.body, by: x.saved_by, at: x.saved_at }))];
		}).catch((e) => (error = e.message));
		loadComments(s);
	});

	// comments in the diff (guy, 11-13): select on the new side -> saved against the newer version, on the
	// deleted/old side -> against the older one. The source is stripped of markup (anchor.ts stripLine) so
	// the same comment also anchors on the rendered doc page, and comments made there show here, per line.
	type Cmt = { id: number; slug: string; version: number; quote: string; prefix: string; body: string;
		author: string; created_at: string; resolved_at: string | null };
	let comments = $state<Cmt[]>([]);
	const loadComments = (s: string) =>
		api<Cmt[]>(`/doc_comments?slug=eq.${encodeURIComponent(s)}&resolved_at=is.null&order=created_at`)
			.then((r) => (comments = r.data)).catch(() => {});
	function lineMap(v: V | undefined): Map<number, number[]> {
		const m = new Map<number, number[]>();
		if (!v || !v.version) return m;
		for (const c of comments) {
			const q = quoteLines(v.body, v.format, c.quote, c.prefix);
			if (q) for (const l of q.lines) m.set(l, [...(m.get(l) ?? []), c.id]);
		}
		return m;
	}
	const idsFor = (side: 'old' | 'new', line?: number) => (line ? (side === 'old' ? oldMap : newMap).get(line) ?? [] : []);
	let sel = $state<{ side: 'old' | 'new'; quote: string; prefix: string; suffix: string; x: number; y: number } | null>(null);
	let composing = $state(false), draft = $state(''), saving = $state(false), cerr = $state('');
	let hover = $state<{ ids: number[]; x: number; y: number; pinned: boolean } | null>(null);
	function onSelect() {
		setTimeout(() => {
			const s = window.getSelection();
			if (!s || s.isCollapsed || !s.rangeCount || !from || !to) { if (!composing) sel = null; return; }
			const r = s.getRangeAt(0);
			const cell = (r.startContainer.nodeType === 1 ? r.startContainer as Element : r.startContainer.parentElement)?.closest('td[data-side]') as HTMLElement | null;
			if (!cell) { if (!composing) sel = null; return; }
			const side = cell.dataset.side as 'old' | 'new', line = Number(cell.dataset.line);
			const v = side === 'old' ? from : to;
			const quote = norm(r.toString().split('\n').map((l) => stripLine(l, v.format)).join(' ')).trim();
			if (!quote) return;
			const hit = quoteLines(v.body, v.format, quote, '', line);
			const box = r.getBoundingClientRect();
			if (!hit) { sel = null; cerr = ''; return; }
			sel = { side, quote: quote.slice(0, 2000), prefix: hit.prefix, suffix: hit.suffix,
				x: Math.min(box.left + box.width / 2, innerWidth - 60), y: box.bottom };
			composing = false; cerr = '';
		}, 0);
	}
	async function saveComment() {
		if (!sel || !from || !to || !draft.trim()) return;
		saving = true; cerr = '';
		try {
			await api('/rpc/doc_comment', { body: { slug, quote: sel.quote, body: draft.trim(),
				version: sel.side === 'old' ? from.version : to.version, prefix: sel.prefix, suffix: sel.suffix } });
			draft = ''; sel = null; composing = false; window.getSelection()?.removeAllRanges();
			await loadComments(slug);
		} catch (e) { cerr = (e as Error).message; } finally { saving = false; }
	}
	async function resolve(c: Cmt) {
		try { await api('/rpc/doc_comment_resolve', { body: { id: c.id, resolved: true } }); await loadComments(slug); hover = null; }
		catch (e) { alert((e as Error).message); }
	}
	function idsOf(el: Element | null) { const td = el?.closest('td[data-ids]') as HTMLElement | null; return td ? { td, ids: td.dataset.ids!.split(',').map(Number) } : null; }
	function onOver(e: MouseEvent) {
		if (hover?.pinned) return;
		const h = idsOf(e.target as Element);
		if (!h) { hover = null; return; }
		const b = h.td.getBoundingClientRect();
		hover = { ids: h.ids, x: Math.min(b.left, innerWidth - 340), y: b.bottom + 2, pinned: false };
	}
	function onTap(e: MouseEvent) {
		const h = idsOf(e.target as Element);
		if (h && window.getSelection()?.isCollapsed) { const b = h.td.getBoundingClientRect(); hover = { ids: h.ids, x: Math.min(b.left, innerWidth - 340), y: b.bottom + 2, pinned: true }; }
	}
	const byId = (id: number) => comments.find((c) => c.id === id);

	// v0 = the empty document before the first draft, so the whole history can be played from nothing
	const EMPTY: V = { version: 0, title: '', format: 'md', body: '', by: '', at: '' };
	const choices = $derived(all.length ? [...all, EMPTY] : []);
	const num = (k: string) => {
		const raw = page.url.searchParams.get(k);
		const n = raw === null || raw === '' ? NaN : Number(raw);
		return Number.isInteger(n) && n >= 0 ? n : null;
	};
	const to = $derived(all.find((v) => v.version === num('to')) ?? all[0]);
	const from = $derived(choices.find((v) => v.version === num('from'))
		?? all.find((v) => to && v.version < to.version) ?? (to ? EMPTY : undefined));
	const oldMap = $derived(lineMap(from));
	const newMap = $derived(lineMap(to));
	// stepping: each step is one save (previous version -> this one), oldest first
	const asc = $derived([...all].reverse());
	const stepAt = $derived(to ? asc.findIndex((v) => v.version === to.version) : -1);
	const isStep = $derived(!!from && stepAt >= 0 && from.version === (stepAt > 0 ? asc[stepAt - 1].version : 0));
	function go(k: number) {
		if (!asc.length) return;
		const i = Math.max(0, Math.min(asc.length - 1, k));
		pick(i > 0 ? asc[i - 1].version : 0, asc[i].version);
	}
	function onKey(e: KeyboardEvent) {
		// Alt+N / Alt+P (guy's shortcut): newer / older change, from anywhere on the page. e.code, since
		// macOS turns Alt+N into a dead key in e.key.
		if (e.altKey && !e.ctrlKey && !e.metaKey && (e.code === 'KeyN' || e.code === 'KeyP')) {
			e.preventDefault(); go(stepAt + (e.code === 'KeyN' ? 1 : -1)); return;
		}
		const t = e.target as HTMLElement;
		if (e.altKey || e.ctrlKey || e.metaKey || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable) return;
		const k = e.key;
		if (k === 'ArrowLeft' || k === 'j' || k === '[') { e.preventDefault(); go(stepAt - 1); }
		else if (k === 'ArrowRight' || k === 'k' || k === ']') { e.preventDefault(); go(stepAt + 1); }
		else if (k === 'Home') { e.preventDefault(); go(0); }
		else if (k === 'End') { e.preventDefault(); go(asc.length - 1); }
		else if (k === 'u') setMode(mode === 'unified' ? 'split' : 'unified');
	}
	const label = (v: V) => (v.version === 0 ? '(empty, before v1)' : `v${v.version} · ${fmtTime(v.at)} · ${v.by}`);
	const rows = $derived(from && to ? diffLines(from.body, to.body) : []);
	const hs = $derived(hunks(rows));
	const st = $derived(stats(rows));
	$effect(() => { void from; void to; opened = new Set(); });

	function pick(f: number, t: number) {
		goto(`/docs/${encodeURIComponent(slug)}/diff?from=${f}&to=${t}`, { replaceState: true });
	}
	const toggle = (i: number) => { const s = new Set(opened); if (s.has(i)) s.delete(i); else s.add(i); opened = s; };

	// side-by-side: eq rows on both sides; within a change run, dels left and adds right, by index
	type Pair = { l?: Row; r?: Row };
	function pairs(rs: Row[]): Pair[] {
		const out: Pair[] = [];
		let k = 0;
		while (k < rs.length) {
			if (rs[k].op === 'eq') { out.push({ l: rs[k], r: rs[k] }); k++; continue; }
			const d: Row[] = [], a: Row[] = [];
			while (k < rs.length && rs[k].op !== 'eq') (rs[k].op === 'del' ? d : a).push(rs[k++]);
			for (let p = 0; p < Math.max(d.length, a.length); p++) out.push({ l: d[p], r: a[p] });
		}
		return out;
	}
	const isSkip = (h: Hunk): h is { skip: Row[] } => 'skip' in h;
	const sign = { eq: ' ', del: '−', add: '+' } as const;
</script>

{#snippet text(r: Row)}{#if r.segs}{#each r.segs as s}{#if s.op === 'eq'}{s.text}{:else}<mark class={s.op}>{s.text}</mark>{/if}{/each}{:else}{r.text}{/if}{/snippet}

{#snippet unifiedRows(rs: Row[])}
	{#each rs as r}
		{@const side = r.op === 'del' ? 'old' : 'new'}{@const line = side === 'old' ? r.a : r.b}{@const ids = idsFor(side, line)}
		<tr class={r.op}><td class="n">{r.a ?? ''}</td><td class="n">{r.b ?? ''}</td><td class="s">{sign[r.op]}</td><td class="t" class:hc={ids.length}
			data-side={side} data-line={line} data-ids={ids.length ? ids.join(',') : undefined}>{@render text(r)}{#if ids.length}<span class="cm">💬{ids.length > 1 ? ids.length : ''}</span>{/if}</td></tr>
	{/each}
{/snippet}

{#snippet splitRows(rs: Row[])}
	{#each pairs(rs) as p}
		{@const li = idsFor('old', p.l?.a)}{@const ri = idsFor('new', p.r?.b)}
		<tr>
			<td class="n">{p.l?.a ?? ''}</td><td class="t {p.l ? (p.l.op === 'eq' ? 'eq' : 'del') : 'none'}" class:hc={li.length}
				data-side={p.l ? 'old' : undefined} data-line={p.l?.a} data-ids={li.length ? li.join(',') : undefined}>{#if p.l}{@render text(p.l)}{/if}{#if li.length}<span class="cm">💬{li.length > 1 ? li.length : ''}</span>{/if}</td>
			<td class="n">{p.r?.b ?? ''}</td><td class="t {p.r ? (p.r.op === 'eq' ? 'eq' : 'add') : 'none'}" class:hc={ri.length}
				data-side={p.r ? 'new' : undefined} data-line={p.r?.b} data-ids={ri.length ? ri.join(',') : undefined}>{#if p.r}{@render text(p.r)}{/if}{#if ri.length}<span class="cm">💬{ri.length > 1 ? ri.length : ''}</span>{/if}</td>
		</tr>
	{/each}
{/snippet}

<svelte:window onkeydown={onKey} />
<p><a href="/docs/{slug}">← doc:{slug}</a></p>
{#if error}<p class="error">{error}</p>{/if}
{#if from && to}
	<h1 class="title">{to.title} <span class="muted">· changes</span></h1>
	<nav class="steps">
		<button onclick={() => go(0)} disabled={isStep && stepAt === 0} title="first draft (Home)">⏮</button>
		<button onclick={() => go(stepAt - 1)} disabled={stepAt <= 0} title="older change (Alt+P, ← or j)">◀ older</button>
		<span class="pos">{#if isStep}change {stepAt + 1} of {asc.length}: {stepAt === 0 ? 'first draft' : `v${from.version} → v${to.version}`}{:else}v{from.version} → v{to.version}{/if}</span>
		<button onclick={() => go(stepAt + 1)} disabled={stepAt >= asc.length - 1} title="newer change (Alt+N, → or k)">newer ▶</button>
		<button onclick={() => go(asc.length - 1)} disabled={isStep && stepAt === asc.length - 1} title="latest change (End)">⏭</button>
		<span class="keys muted">Alt+P / Alt+N (or ← →) step · Home/End · u view</span>
	</nav>
	<header class="bar">
		<label>from <select value={from.version} onchange={(e) => pick(Number(e.currentTarget.value), to.version)}>
			{#each choices as v}<option value={v.version}>{label(v)}</option>{/each}
		</select></label>
		<label>to <select value={to.version} onchange={(e) => pick(from.version, Number(e.currentTarget.value))}>
			{#each all as v}<option value={v.version}>v{v.version} · {fmtTime(v.at)} · {v.by}</option>{/each}
		</select></label>
		<span class="stat"><span class="plus">+{st.add}</span> <span class="minus">−{st.del}</span></span>
		<span class="modes">
			<button class:on={mode === 'unified'} onclick={() => setMode('unified')}>unified</button>
			<button class:on={mode === 'split'} onclick={() => setMode('split')}>side by side</button>
		</span>
	</header>

	{#if from.version === to.version}
		<p class="muted">Same version on both sides. Pick another one.</p>
	{:else if !st.add && !st.del}
		<p class="muted">No changes in the text{from.title !== to.title ? ` (title changed: "${from.title}" → "${to.title}")` : ''}.</p>
	{:else}
		{#if from.version && from.title !== to.title}<p class="muted">Title: <del>{from.title}</del> → <ins>{to.title}</ins></p>{/if}
		<div class="wrap panel">
			<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions, a11y_mouse_events_have_key_events -->
			<table class="diff {mode}" onmouseup={onSelect} ontouchend={onSelect} onmouseover={onOver} onclick={onTap}
				onmouseleave={() => { if (!hover?.pinned) hover = null; }}><tbody>
				{#each hs as h, i}
					{#if isSkip(h)}
						{#if opened.has(i)}
							{#if mode === 'unified'}{@render unifiedRows(h.skip)}{:else}{@render splitRows(h.skip)}{/if}
						{:else}
							<tr class="fold"><td colspan="4"><button class="link" onclick={() => toggle(i)}>⋯ {h.skip.length} unchanged line{h.skip.length === 1 ? '' : 's'}</button></td></tr>
						{/if}
					{:else if mode === 'unified'}{@render unifiedRows(h.rows)}{:else}{@render splitRows(h.rows)}{/if}
				{/each}
			</tbody></table>
		</div>
	{/if}

	<p class="hint muted">Select text to comment: on the new side it's saved against v{to.version}{from.version ? `, on the old side against v${from.version}` : ''}. 💬 marks commented lines; hover or tap to read.</p>

	{#if sel}
		<div class="cbox" style="left:{Math.max(8, Math.min(sel.x - 160, innerWidth - 336))}px; top:{sel.y + 6}px">
			{#if !composing}
				<button onmousedown={(e) => e.preventDefault()} onclick={() => (composing = true)}>💬 Comment on v{sel.side === 'old' ? from.version : to.version}</button>
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
					<div class="who muted">{c.author} · {ago(c.created_at)} · on v{c.version}</div>
					<blockquote>{c.quote.length > 160 ? c.quote.slice(0, 160) + '…' : c.quote}</blockquote>
					<div class="body">{c.body}</div>
					<div class="acts"><a href="/docs/{slug}#comment-{c.id}">on the doc</a> · <button class="link" onclick={() => resolve(c)}>resolve</button></div>
				</div>
			{/if}{/each}
			{#if hover.pinned}<button class="link close" onclick={() => (hover = null)}>close</button>{/if}
		</div>
	{/if}

	<section class="hist">
		<h2>Versions</h2>
		<ul>
			{#each all as v, k}
				<li>
					<span class="mono">v{v.version}</span> · {fmtTime(v.at)} · {v.by}
					· <a href="/docs/{slug}/diff?from={all[k + 1]?.version ?? 0}&to={v.version}">{all[k + 1] ? `changes vs v${all[k + 1].version}` : 'first draft'}</a>
				</li>
			{/each}
		</ul>
	</section>
{/if}

<style>
	.steps { display: flex; flex-wrap: wrap; gap: 0.4rem; align-items: center; font-size: 0.85rem; margin-bottom: 0.5rem; }
	.steps button { font-size: 0.82rem; padding: 0.15rem 0.55rem; }
	.steps .pos { font-family: var(--mono); font-size: 0.8rem; min-width: 12rem; text-align: center; }
	.steps .keys { font-size: 0.72rem; }
	@media (max-width: 640px) { .steps .keys { display: none; } .steps .pos { min-width: 0; } }
	.title { font-size: 1.25rem; margin: 0.2rem 0 0.6rem; }
	.bar { display: flex; flex-wrap: wrap; gap: 0.5rem 0.9rem; align-items: center; font-size: 0.82rem; margin-bottom: 0.7rem; }
	.bar select { width: auto; max-width: 100%; font-size: 0.8rem; padding: 0.1rem 0.3rem; }
	.stat { font-family: var(--mono); }
	.plus { color: var(--diff-add-fg); } .minus { color: var(--diff-del-fg); }
	.modes button { font-size: 0.78rem; padding: 0.15rem 0.5rem; }
	.modes button.on { font-weight: 600; outline: 1px solid var(--line); }
	.wrap { overflow-x: auto; padding: 0; }
	table.diff { border-collapse: collapse; width: 100%; font-family: var(--mono); font-size: 0.78rem; line-height: 1.45; }
	table.diff td { vertical-align: top; padding: 0 0.4rem; }
	td.n { color: var(--muted, #888); text-align: right; user-select: none; width: 1%; white-space: nowrap; }
	td.s { width: 1%; user-select: none; color: var(--muted, #888); }
	td.t { white-space: pre-wrap; overflow-wrap: anywhere; }
	table.split td.t { width: 50%; }
	tr.add td, td.t.add { background: var(--diff-add-bg); }
	tr.del td, td.t.del { background: var(--diff-del-bg); }
	td.t.none { background: color-mix(in srgb, var(--line) 25%, transparent); }
	mark { color: inherit; border-radius: 2px; }
	mark.add { background: var(--diff-add-mark); }
	mark.del { background: var(--diff-del-mark); text-decoration: line-through; text-decoration-color: color-mix(in srgb, currentColor 45%, transparent); }
	tr.fold td { background: color-mix(in srgb, var(--line) 30%, transparent); text-align: center; padding: 0.15rem; }
	td.t.hc { box-shadow: inset 3px 0 0 #e0a800; cursor: pointer; }
	.cm { float: right; font-size: 0.7rem; margin-left: 0.4rem; user-select: none; }
	.hint { font-size: 0.75rem; margin: 0.4rem 0 0; }
	.cbox, .pop { position: fixed; z-index: 50; background: var(--bg, #fff); border: 1px solid var(--line); border-radius: 8px;
		box-shadow: 0 6px 24px rgba(0,0,0,0.18); padding: 0.5rem; width: min(320px, calc(100vw - 16px)); font-size: 0.85rem; }
	.cbox:has(> button:only-child) { width: auto; padding: 0.2rem; }
	.cbox textarea { width: 100%; box-sizing: border-box; font: inherit; }
	.cbox blockquote, .pop blockquote { margin: 0 0 0.35rem; padding-left: 0.5rem; border-left: 3px solid #e0a800; font-size: 0.8rem; max-height: 6rem; overflow: auto; }
	.cbox .row { display: flex; gap: 0.6rem; align-items: center; margin-top: 0.3rem; }
	.pop { max-height: 50vh; overflow: auto; }
	.pc + .pc { border-top: 1px solid var(--line); margin-top: 0.4rem; padding-top: 0.4rem; }
	.pc .body { white-space: pre-wrap; overflow-wrap: anywhere; }
	.who, .acts, .close { font-size: 0.75rem; }
	.hist { margin-top: 1.4rem; font-size: 0.85rem; }
	.hist h2 { font-size: 1rem; }
	.hist ul { padding-left: 1.1rem; }
	del { color: var(--diff-del-fg); } ins { color: var(--diff-add-fg); text-decoration: none; }
	:global(:root) { --diff-add-bg: #e6ffec; --diff-add-mark: #abf2bc; --diff-add-fg: #1a7f37;
		--diff-del-bg: #ffebe9; --diff-del-mark: #ffc1bc; --diff-del-fg: #cf222e; }
	@media (prefers-color-scheme: dark) {
		:global(:root:not([data-theme='light'])) { --diff-add-bg: #12361f; --diff-add-mark: #1f6b3a; --diff-add-fg: #56d364;
			--diff-del-bg: #3d1618; --diff-del-mark: #7d2a2e; --diff-del-fg: #f85149; }
	}
	:global(:root[data-theme='dark']) { --diff-add-bg: #12361f; --diff-add-mark: #1f6b3a; --diff-add-fg: #56d364;
		--diff-del-bg: #3d1618; --diff-del-mark: #7d2a2e; --diff-del-fg: #f85149; }
	@media (max-width: 640px) { table.split { font-size: 0.7rem; } }
</style>
