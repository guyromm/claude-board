<script lang="ts">
	// BATCH REVIEW (guy, 11-26): the open reviews of one repo under a size threshold (lines added + removed < max, default 500)
	// on one screen, each with its description, notes, comments and diff, for one pass. Each review keeps its own Approve /
	// Request changes; keys act on the review at the top of the screen, and "Approve all" approves every one still open.
	// URL: /reviews/batch?repo=<repo>&max=500 (no repo: the repos that have 2+ such reviews).
	import { page } from '$app/state';
	import { replaceState } from '$app/navigation';
	import { tick } from 'svelte';
	import { api, session } from '#lib/api.svelte.ts';
	import { head } from '#lib/title.svelte.ts';
	import ReviewView from '#lib/ReviewView.svelte';

	type Row = { id: number; agent: string; repo: string; title: string; status: string; adds: number; dels: number; files: number; open_comments: number };
	type View = { decide: (d: 'approve' | 'changes') => Promise<boolean>; status: () => string | null };

	const sp = page.url.searchParams;
	let repo = $state(sp.get('repo') ?? '');
	let max = $state(Number(sp.get('max')) > 0 ? Number(sp.get('max')) : 500);
	let rows = $state<Row[]>([]);
	let error = $state('');
	let loaded = $state(false);
	$effect(() => {
		api<Row[]>('/reviews?select=id,agent,repo,title,status,adds,dels,files,open_comments&status=eq.open&order=id')
			.then((r) => { rows = r.data; loaded = true; }).catch((e) => (error = e.message));
	});
	$effect(() => {
		const u = new URLSearchParams();
		if (repo) u.set('repo', repo);
		if (max !== 500) u.set('max', String(max));
		const next = u.toString() ? `?${u}` : '';
		if (next !== location.search) replaceState(`/reviews/batch${next}`, {});
	});
	$effect(() => { head.title = repo ? `Batch review: ${repo}` : 'Batch review'; });

	const small = $derived(rows.filter((r) => r.adds + r.dels < max));
	const repos = $derived.by(() => {
		const m = new Map<string, Row[]>();
		for (const r of small) m.set(r.repo, [...(m.get(r.repo) ?? []), r]);
		return [...m.entries()].map(([name, rs]) => ({ name, rs, adds: rs.reduce((s, r) => s + r.adds, 0), dels: rs.reduce((s, r) => s + r.dels, 0) }))
			.sort((a, b) => b.rs.length - a.rs.length || a.name.localeCompare(b.name));
	});
	// the batch is fixed once loaded: a review stays on screen after it is decided (its badge changes), so nothing jumps
	const batch = $derived(small.filter((r) => r.repo === repo));
	let decided = $state<Record<number, string>>({});
	const views: Record<number, View> = {};
	const stillOpen = $derived(batch.filter((r) => (decided[r.id] ?? 'open') === 'open'));
	const isAdmin = $derived(!!session.current?.is_admin);

	// the review at the top of the screen: the last section whose top has passed the sticky bar
	function current(): number | null {
		let cur: number | null = batch[0]?.id ?? null;
		for (const r of batch) {
			const el = document.getElementById(`rv${r.id}`);
			if (el && el.getBoundingClientRect().top <= 140) cur = r.id;
		}
		return cur;
	}
	async function jump(id: number | undefined) {
		if (id === undefined) return;
		await tick();
		document.getElementById(`rv${id}`)?.scrollIntoView({ block: 'start' });
	}
	const nextOpen = (after: number) => stillOpen.find((r) => r.id > after)?.id ?? stillOpen.find((r) => r.id !== after)?.id;
	async function decideCurrent(d: 'approve' | 'changes') {
		const id = current(); if (id === null) return;
		if (await views[id]?.decide(d)) jump(nextOpen(id));
	}
	let all = $state<{ done: number; n: number; failed: number[] } | null>(null);
	async function approveAll() {
		const ids = stillOpen.map((r) => r.id);
		if (!ids.length || !confirm(`Approve all ${ids.length} open reviews of ${repo}? Each agent gets its approval and merges.`)) return;
		all = { done: 0, n: ids.length, failed: [] };
		for (const id of ids) {
			const ok = await views[id]?.decide('approve');
			if (ok) all.done++; else all.failed.push(id);
		}
	}

	// keys (capture phase, like the single review page): Alt+A approve and Alt+J request changes on the review at the top,
	// then on to the next open one; Alt+N / Alt+P next / previous review
	$effect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (!e.altKey || e.ctrlKey || e.metaKey || !repo || !batch.length) return;
			const k = e.code.startsWith('Key') ? e.code.slice(3).toLowerCase() : '';
			if (!['a', 'j', 'n', 'p'].includes(k)) return;
			e.preventDefault();
			if (k === 'a' && isAdmin) decideCurrent('approve');
			else if (k === 'j' && isAdmin) decideCurrent('changes');
			else {
				const id = current(); const i = batch.findIndex((r) => r.id === id);
				jump(batch[Math.max(0, Math.min(batch.length - 1, i + (k === 'n' ? 1 : -1)))]?.id);
			}
		};
		window.addEventListener('keydown', onKey, true);
		return () => window.removeEventListener('keydown', onKey, true);
	});
	const label: Record<string, string> = { open: 'to review', approved: 'approved', changes: 'changes', merged: 'merged', closed: 'closed' };
</script>

<p><a href="/reviews">← Code reviews</a></p>
<h1>Batch review</h1>
<div class="bar">
	<label class="small">repo
		<select bind:value={repo}>
			<option value="">choose…</option>
			{#each repos as g}<option value={g.name}>{g.name} ({g.rs.length})</option>{/each}
			{#if repo && !repos.some((g) => g.name === repo)}<option value={repo}>{repo} (0)</option>{/if}
		</select>
	</label>
	<label class="small">under <input type="number" min="1" step="50" bind:value={max} class="num" /> lines (+ and −)</label>
</div>
{#if error}<p class="error">{error}</p>{/if}

{#if !repo}
	{#if loaded}
		<p class="muted small">Open reviews under {max} changed lines, by repo. Pick one to read them all on one screen.</p>
		<ul class="groups">
			{#each repos as g}
				<li><a href="/reviews/batch?repo={encodeURIComponent(g.name)}{max !== 500 ? `&max=${max}` : ''}" onclick={(e) => { e.preventDefault(); repo = g.name; }}>
					<span class="mono">{g.name}</span></a> · {g.rs.length} review{g.rs.length === 1 ? '' : 's'} ·
					<span class="plus">+{g.adds}</span> <span class="minus">−{g.dels}</span>
					<span class="muted">({g.rs.map((r) => r.agent).filter((a, i, xs) => xs.indexOf(a) === i).join(', ')})</span></li>
			{:else}<li class="muted">No open reviews under {max} lines.</li>{/each}
		</ul>
	{/if}
{:else}
	<div class="sticky panel">
		<span class="mono"><b>{repo}</b></span>
		<span class="small">{batch.length} review{batch.length === 1 ? '' : 's'} · {stillOpen.length} still open ·
			<span class="plus">+{batch.reduce((s, r) => s + r.adds, 0)}</span> <span class="minus">−{batch.reduce((s, r) => s + r.dels, 0)}</span></span>
		<nav class="chips">
			{#each batch as r (r.id)}
				<button class="chip s-{decided[r.id] ?? 'open'}" title="{r.agent}: {r.title} (+{r.adds} −{r.dels})" onclick={() => jump(r.id)}>!{r.id}</button>
			{/each}
		</nav>
		{#if isAdmin && stillOpen.length}
			<button class="ok" onclick={approveAll} disabled={!!all && all.done + all.failed.length < all.n}>✓ Approve all {stillOpen.length}</button>
		{/if}
		{#if all}<span class="small">{all.done} of {all.n} approved{#if all.failed.length} · failed: {all.failed.map((x) => `!${x}`).join(', ')}{/if}</span>{/if}
		<span class="muted small keys">Alt+A approve · Alt+J request changes (the review at the top, then the next) · Alt+N / Alt+P next / previous</span>
	</div>
	{#if loaded && !batch.length}<p class="muted">No open reviews of {repo} under {max} lines.</p>{/if}
	{#each batch as r (r.id)}
		<article class="rv" id="rv{r.id}">
			<div class="rvhead small"><span class="mono">!{r.id}</span> · {r.agent} · <span class="badge s-{decided[r.id] ?? 'open'}">{label[decided[r.id] ?? 'open'] ?? decided[r.id]}</span></div>
			<ReviewView id={r.id} group bind:this={views[r.id]} ondecided={(id, s) => (decided = { ...decided, [id]: s })} />
		</article>
	{/each}
{/if}

<style>
	.small { font-size: 0.8rem; }
	.bar { display: flex; flex-wrap: wrap; gap: 0.5rem 1.2rem; align-items: center; margin: 0.4rem 0 0.8rem; }
	.bar select { width: auto; }
	input.num { width: 5.5rem; }
	.groups { line-height: 1.8; font-size: 0.9rem; }
	.sticky { position: sticky; top: 0; z-index: 5; display: flex; flex-wrap: wrap; gap: 0.4rem 0.9rem; align-items: center;
		padding: 0.45rem 0.7rem; background: var(--bg, #fff); }
	.chips { display: flex; flex-wrap: wrap; gap: 0.25rem; }
	.chip { font-size: 0.72rem; padding: 0.05rem 0.45rem; border-radius: 999px; border: 1px solid var(--line); font-family: var(--mono); }
	.keys { flex-basis: 100%; }
	.rv { margin: 1.4rem 0 2rem; padding-top: 0.6rem; border-top: 3px solid var(--line); scroll-margin-top: 7.5rem; }
	.rvhead { margin-bottom: 0.2rem; }
	button.ok { background: #1a7f37; color: #fff; border-color: #1a7f37; }
	.plus { color: #1a7f37; } .minus { color: #cf222e; }
	.badge { padding: 0.05rem 0.45rem; border-radius: 999px; font-size: 0.72rem; border: 1px solid var(--line); }
	.s-open { background: #fff4d6; color: #7a5200; } .s-approved { background: #dafbe1; color: #1a7f37; }
	.s-changes { background: #ffebe9; color: #a40e26; } .s-merged { background: #ece4ff; color: #5a32a3; }
	@media (prefers-color-scheme: dark) {
		:global(:root:not([data-theme='light'])) .s-open { background: #3d2e00; color: #f5c542; }
	}
</style>
