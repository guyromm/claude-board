<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { tick } from 'svelte';
	import { api, ago, fmtTime, session } from '#lib/api.svelte.ts';
	import { parseDiff, type DFile, type DLine } from '#lib/udiff.ts';

	type R = { id: number; agent: string; repo: string; branch: string; base: string; title: string; description: string;
		compare_url: string | null; task_path: string | null; status: string; decided_by: string | null; decided_at: string | null;
		decision_note: string | null; merged_sha: string | null; rev: number; head_sha: string | null; created_at: string; updated_at: string };
	type Rev = { review_id: number; rev: number; head_sha: string | null; files: number; adds: number; dels: number; note: string | null; created_at: string };
	type C = { id: number; review_id: number; rev: number; path: string; side: 'old' | 'new'; line: number | null; quote: string;
		body: string; author: string; created_at: string; resolved_at: string | null; resolved_by: string | null };

	const id = $derived(Number(page.params.id));
	let r = $state<R | null>(null);
	let revs = $state<Rev[]>([]);
	let diffText = $state('');
	let comments = $state<C[]>([]);
	let error = $state('');
	let collapsed = $state<Set<string>>(new Set());

	const want = $derived(Number(page.url.searchParams.get('rev')) || null);
	const rev = $derived(want && revs.some((v) => v.rev === want) ? want : (revs[0]?.rev ?? null));
	const files = $derived<DFile[]>(diffText ? parseDiff(diffText) : []);
	const isAdmin = $derived(!!session.current?.is_admin);

	async function loadAll() {
		try {
			const [a, b] = await Promise.all([
				api<R[]>(`/reviews?id=eq.${id}`),
				api<Rev[]>(`/review_revs?review_id=eq.${id}&select=review_id,rev,head_sha,files,adds,dels,note,created_at&order=rev.desc`),
			]);
			if (!a.data.length) throw new Error(`no review #${id}`);
			r = a.data[0]; revs = b.data;
			await loadComments();
		} catch (e) { error = (e as Error).message; }
	}
	const loadComments = () => api<C[]>(`/review_comments?review_id=eq.${id}&order=created_at`).then((x) => (comments = x.data));
	$effect(() => { void id; r = null; revs = []; diffText = ''; comments = []; error = ''; loadAll(); });
	$effect(() => {
		const v = rev;
		if (v === null) return;
		api<{ diff: string }[]>(`/review_revs?review_id=eq.${id}&rev=eq.${v}&select=diff`).then((x) => {
			diffText = x.data[0]?.diff ?? '';
			const big = new Set<string>();
			for (const f of parseDiff(diffText)) if (f.adds + f.dels > 600) big.add(f.path);
			collapsed = big;
			const m = /^#c(\d+)$/.exec(location.hash);
			if (m) tick().then(() => document.getElementById(`c${m[1]}`)?.scrollIntoView({ block: 'center' }));
		}).catch((e) => (error = e.message));
	});

	const here = $derived(comments.filter((c) => c.rev === rev));
	const elsewhere = $derived(comments.filter((c) => c.rev !== rev));
	const general = $derived(here.filter((c) => !c.path));
	const key = (path: string, side: string, line: number | undefined) => `${path}|${side}|${line}`;
	const byLine = $derived.by(() => {
		const m = new Map<string, C[]>();
		for (const c of here) if (c.path && c.line != null) { const k = key(c.path, c.side, c.line); m.set(k, [...(m.get(k) ?? []), c]); }
		return m;
	});
	// a line's comments: new-side ones on + and context lines, old-side ones on - lines (and context, by old number)
	function lineComments(path: string, l: DLine): C[] {
		const out: C[] = [];
		if (l.new !== undefined) out.push(...(byLine.get(key(path, 'new', l.new)) ?? []));
		if (l.old !== undefined) out.push(...(byLine.get(key(path, 'old', l.old)) ?? []));
		return out;
	}
	const fileComments = (path: string) => here.filter((c) => c.path === path && c.line == null);

	// composing: a line (click its number) or a selection inside a line
	let compose = $state<{ path: string; side: 'old' | 'new'; line: number | null; quote: string } | null>(null);
	let draft = $state(''), saving = $state(false), cerr = $state('');
	const sideOf = (l: DLine): 'old' | 'new' => (l.t === '-' ? 'old' : 'new');
	const numOf = (l: DLine) => (l.t === '-' ? l.old! : l.new!);
	function startLine(path: string, l: DLine) { compose = { path, side: sideOf(l), line: numOf(l), quote: '' }; draft = ''; cerr = ''; }
	function onSelect() {
		setTimeout(() => {
			const s = window.getSelection();
			if (!s || s.isCollapsed || !s.rangeCount) return;
			const rg = s.getRangeAt(0);
			const el = (rg.startContainer.nodeType === 1 ? rg.startContainer as Element : rg.startContainer.parentElement)?.closest('tr[data-path]') as HTMLElement | null;
			if (!el) return;
			const quote = rg.toString().trim();
			if (!quote) return;
			compose = { path: el.dataset.path!, side: el.dataset.side as 'old' | 'new', line: Number(el.dataset.line), quote: quote.slice(0, 4000) };
			if (!draft) cerr = '';
		}, 0);
	}
	async function save() {
		if (!compose || !draft.trim() || rev === null) return;
		saving = true; cerr = '';
		try {
			await api('/rpc/review_comment', { body: { id, body: draft.trim(), rev, path: compose.path, side: compose.side,
				line: compose.line, quote: compose.quote } });
			compose = null; draft = ''; window.getSelection()?.removeAllRanges();
			await loadComments();
		} catch (e) { cerr = (e as Error).message; } finally { saving = false; }
	}
	let generalDraft = $state('');
	async function saveGeneral() {
		if (!generalDraft.trim()) return;
		try { await api('/rpc/review_comment', { body: { id, body: generalDraft.trim(), rev } }); generalDraft = ''; await loadComments(); }
		catch (e) { alert((e as Error).message); }
	}
	async function resolve(c: C, yes = true) {
		try { await api('/rpc/review_comment_resolve', { body: { id: c.id, resolved: yes } }); await loadComments(); }
		catch (e) { alert((e as Error).message); }
	}

	// decision
	let reason = $state(''), deciding = $state(false), derr = $state('');
	async function decide(decision: 'approve' | 'changes') {
		deciding = true; derr = '';
		try { await api('/rpc/review_decide', { body: { id, decision, note: reason.trim() || null } }); reason = ''; await loadAll(); }
		catch (e) { derr = (e as Error).message; } finally { deciding = false; }
	}

	const pickRev = (v: number) => goto(`/reviews/${id}?rev=${v}`, { replaceState: true });
	const toggle = (p: string) => { const s = new Set(collapsed); if (s.has(p)) s.delete(p); else s.add(p); collapsed = s; };
	const anchor = (p: string) => 'f-' + p.replace(/[^\w.-]+/g, '_');
	const label: Record<string, string> = { open: 'to review', approved: 'approved: the agent merges', changes: 'changes requested',
		merged: 'merged', closed: 'closed' };
	const openCount = $derived(comments.filter((c) => !c.resolved_at).length);
</script>

{#snippet thread(cs: C[])}
	{#each cs as c (c.id)}
		<div class="cm" class:resolved={c.resolved_at} id="c{c.id}">
			<div class="who muted">{c.author} · {ago(c.created_at)}{c.resolved_at ? ` · resolved by ${c.resolved_by}` : ''}
				· <a href="#c{c.id}">link</a> ·
				{#if c.resolved_at}<button class="link" onclick={() => resolve(c, false)}>reopen</button>{:else}<button class="link" onclick={() => resolve(c)}>resolve</button>{/if}</div>
			{#if c.quote}<blockquote>{c.quote.length > 300 ? c.quote.slice(0, 300) + '…' : c.quote}</blockquote>{/if}
			<div class="body">{c.body}</div>
		</div>
	{/each}
{/snippet}

{#snippet composer()}
	<div class="composer">
		{#if compose?.quote}<blockquote>{compose.quote.length > 300 ? compose.quote.slice(0, 300) + '…' : compose.quote}</blockquote>{/if}
		<!-- svelte-ignore a11y_autofocus -->
		<textarea bind:value={draft} rows="3" autofocus placeholder="Comment on {compose?.path} {compose?.side} line {compose?.line} (Ctrl+Enter saves)"
			onkeydown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) save(); if (e.key === 'Escape') compose = null; }}></textarea>
		{#if cerr}<p class="error">{cerr}</p>{/if}
		<div class="row"><button onclick={save} disabled={saving || !draft.trim()}>{saving ? 'Saving…' : 'Comment'}</button>
			<button class="link" onclick={() => (compose = null)}>cancel</button></div>
	</div>
{/snippet}

<p><a href="/reviews">← Code reviews</a></p>
{#if error}<p class="error">{error}</p>{/if}
{#if r}
	<h1 class="title">{r.title}</h1>
	<div class="meta muted">
		<span class="badge s-{r.status}">{label[r.status]}</span>
		#{r.id} · {r.agent} · <span class="mono">{r.repo}: {r.branch} → {r.base}</span>
		· rev <select value={rev} onchange={(e) => pickRev(Number(e.currentTarget.value))}>
			{#each revs as v}<option value={v.rev}>{v.rev} · {fmtTime(v.created_at)} · {v.head_sha?.slice(0, 8) ?? ''} · +{v.adds} −{v.dels}</option>{/each}
		</select>
		{#if r.compare_url}· <a href={r.compare_url} target="_blank" rel="noopener">compare on git</a>{/if}
		{#if r.task_path}· <a href="/tasks/{r.task_path}">#{r.task_path}</a>{/if}
		· {openCount} open comment{openCount === 1 ? '' : 's'}
	</div>
	{#if r.description}<div class="desc panel">{r.description}</div>{/if}
	{#if revs.find((v) => v.rev === rev)?.note}<p class="muted small">rev {rev}: {revs.find((v) => v.rev === rev)?.note}</p>{/if}

	<section class="decide panel">
		{#if r.decided_at}<p class="small">Decision: <b>{r.status === 'approved' ? 'approved' : r.status === 'changes' ? 'changes requested' : r.status}</b>
			by {r.decided_by} {ago(r.decided_at)}{#if r.decision_note}: {r.decision_note}{/if}{#if r.merged_sha} · merged {r.merged_sha.slice(0, 10)}{/if}</p>{/if}
		{#if isAdmin && !['merged', 'closed'].includes(r.status)}
			<textarea bind:value={reason} rows="2" placeholder="Note for the agent (required for 'request changes' unless there are open comments)"></textarea>
			{#if derr}<p class="error">{derr}</p>{/if}
			<div class="row">
				<button class="ok" onclick={() => decide('approve')} disabled={deciding}>✓ Approve: merge &amp; push</button>
				<button class="no" onclick={() => decide('changes')} disabled={deciding}>✗ Request changes</button>
				<span class="muted small">{r.agent} gets a board message either way.</span>
			</div>
		{:else if !r.decided_at}<p class="muted small">Waiting for guy's review.</p>{/if}
	</section>

	{#if files.length}
		<nav class="toc">
			{#each files as f}<a href="#{anchor(f.path)}"><span class="mono">{f.path}</span> <span class="plus">+{f.adds}</span> <span class="minus">−{f.dels}</span></a>{/each}
		</nav>
	{/if}
	<p class="muted small">Click a line number to comment on that line, or select text in a line. Comments go to {r.agent}.</p>

	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div onmouseup={onSelect}>
		{#each files as f (f.path)}
			<section class="file panel" id={anchor(f.path)}>
				<header>
					<button class="link" onclick={() => toggle(f.path)}>{collapsed.has(f.path) ? '▸' : '▾'}</button>
					<span class="mono path">{f.status === 'renamed' ? `${f.oldPath} → ${f.newPath}` : f.path}</span>
					{#if f.status !== 'modified'}<span class="tag">{f.status}</span>{/if}
					<span class="plus">+{f.adds}</span> <span class="minus">−{f.dels}</span>
					<button class="link small" onclick={() => { compose = { path: f.path, side: 'new', line: null, quote: '' }; draft = ''; }}>comment on file</button>
				</header>
				{#if fileComments(f.path).length}<div class="filec">{@render thread(fileComments(f.path))}</div>{/if}
				{#if compose && compose.path === f.path && compose.line === null}{@render composer()}{/if}
				{#if !collapsed.has(f.path)}
					{#if f.binary}<p class="muted small pad">binary file</p>
					{:else if !f.hunks.length}<p class="muted small pad">{f.meta.join(' · ') || 'no content change'}</p>
					{:else}
						<div class="wrap"><table class="diff"><tbody>
							{#each f.hunks as h}
								<tr class="hunk"><td colspan="3" class="mono">{h.header}</td></tr>
								{#each h.lines as l}
									{#if l.t === '\\'}<tr class="nl"><td></td><td></td><td class="t muted">{l.text}</td></tr>
									{:else}
										{@const cs = lineComments(f.path, l)}
										<tr class="l{l.t === '+' ? ' add' : l.t === '-' ? ' del' : ''}" data-path={f.path} data-side={sideOf(l)} data-line={numOf(l)}>
											<td class="n"><button class="ln" onclick={() => startLine(f.path, l)} title="comment on this line">{l.old ?? ''}</button></td>
											<td class="n"><button class="ln" onclick={() => startLine(f.path, l)} title="comment on this line">{l.new ?? ''}</button></td>
											<td class="t">{#if l.segs}{#each l.segs as s}{#if s.op === 'eq'}{s.text}{:else}<mark class={s.op}>{s.text}</mark>{/if}{/each}{:else}{l.text}{/if}</td>
										</tr>
										{#if cs.length}<tr class="cmrow"><td colspan="3">{@render thread(cs)}</td></tr>{/if}
										{#if compose && compose.path === f.path && compose.line === numOf(l) && compose.side === sideOf(l)}
											<tr class="cmrow"><td colspan="3">{@render composer()}</td></tr>
										{/if}
									{/if}
								{/each}
							{/each}
						</tbody></table></div>
					{/if}
				{/if}
			</section>
		{/each}
	</div>

	<section class="general">
		<h2>General comments</h2>
		{@render thread(general)}
		<textarea bind:value={generalDraft} rows="3" placeholder="A comment on the whole change"></textarea>
		<button onclick={saveGeneral} disabled={!generalDraft.trim()}>Comment</button>
	</section>
	{#if elsewhere.length}
		<section class="general">
			<h2>Comments on other revisions</h2>
			{#each elsewhere as c}
				<div class="small"><button class="link" onclick={() => pickRev(c.rev)}>rev {c.rev}</button>{c.path ? ` · ${c.path}${c.line != null ? `:${c.line}` : ''}` : ''}</div>
				{@render thread([c])}
			{/each}
		</section>
	{/if}
{/if}

<style>
	.title { font-size: 1.3rem; margin: 0.2rem 0 0.4rem; }
	.meta { font-size: 0.8rem; display: flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; }
	.meta select { width: auto; font-size: 0.78rem; padding: 0.05rem 0.3rem; }
	.small { font-size: 0.8rem; }
	.badge { padding: 0.05rem 0.45rem; border-radius: 999px; font-size: 0.75rem; border: 1px solid var(--line); }
	.s-open { background: #fff4d6; color: #7a5200; } .s-approved { background: #dafbe1; color: #1a7f37; }
	.s-changes { background: #ffebe9; color: #a40e26; } .s-merged { background: #ece4ff; color: #5a32a3; }
	.desc { white-space: pre-wrap; padding: 0.6rem 0.8rem; margin: 0.6rem 0; font-size: 0.88rem; }
	.decide { padding: 0.6rem 0.8rem; margin: 0.7rem 0; }
	.decide textarea, .composer textarea, .general textarea { width: 100%; box-sizing: border-box; font: inherit; }
	.row { display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap; margin-top: 0.3rem; }
	button.ok { background: #1a7f37; color: #fff; border-color: #1a7f37; }
	button.no { background: #cf222e; color: #fff; border-color: #cf222e; }
	.toc { display: flex; flex-direction: column; gap: 0.1rem; font-size: 0.8rem; margin: 0.6rem 0; }
	.file { margin: 0.7rem 0; padding: 0; overflow: hidden; }
	.file header { display: flex; gap: 0.5rem; align-items: center; padding: 0.35rem 0.6rem; border-bottom: 1px solid var(--line);
		background: color-mix(in srgb, var(--line) 30%, transparent); font-size: 0.82rem; flex-wrap: wrap; }
	.path { font-weight: 600; overflow-wrap: anywhere; }
	.tag { font-size: 0.7rem; border: 1px solid var(--line); border-radius: 4px; padding: 0 0.3rem; }
	.pad { padding: 0.4rem 0.6rem; }
	.wrap { overflow-x: auto; }
	table.diff { border-collapse: collapse; width: 100%; font-family: var(--mono); font-size: 0.76rem; line-height: 1.45; }
	td.n { width: 1%; white-space: nowrap; text-align: right; color: var(--muted, #888); user-select: none; padding: 0 0.25rem; }
	button.ln { all: unset; cursor: pointer; padding: 0 0.15rem; }
	button.ln:hover { color: #0969da; text-decoration: underline; }
	td.t { white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 0.5rem; }
	tr.add td { background: var(--diff-add-bg, #e6ffec); } tr.del td { background: var(--diff-del-bg, #ffebe9); }
	mark { color: inherit; border-radius: 2px; }
	mark.add { background: var(--diff-add-mark, #abf2bc); } mark.del { background: var(--diff-del-mark, #ffc1bc); }
	tr.hunk td { background: color-mix(in srgb, #0969da 10%, transparent); color: var(--muted, #666); padding: 0.1rem 0.5rem; }
	tr.cmrow td { padding: 0.3rem 0.6rem; background: var(--bg, #fff); font-family: system-ui, sans-serif; font-size: 0.85rem; }
	.cm { border: 1px solid var(--line); border-left: 3px solid #e0a800; border-radius: 6px; padding: 0.35rem 0.55rem; margin: 0.25rem 0; }
	.cm.resolved { opacity: 0.55; }
	.cm:target { box-shadow: 0 0 0 2px #e0a800; }
	.cm .body { white-space: pre-wrap; overflow-wrap: anywhere; }
	.cm blockquote, .composer blockquote { margin: 0.2rem 0; padding-left: 0.5rem; border-left: 3px solid var(--line); font-family: var(--mono);
		font-size: 0.75rem; white-space: pre-wrap; max-height: 6rem; overflow: auto; }
	.who { font-size: 0.72rem; }
	.composer { padding: 0.3rem 0; }
	.filec { padding: 0.3rem 0.6rem; }
	.general { margin-top: 1.2rem; }
	.general h2 { font-size: 1rem; }
	.plus { color: #1a7f37; } .minus { color: #cf222e; }
	@media (prefers-color-scheme: dark) {
		:global(:root:not([data-theme='light'])) .s-open { background: #3d2e00; color: #f5c542; }
	}
</style>
