<script lang="ts">
	import { api, ago, fmtTime } from '#lib/api.svelte.ts';
	import { page } from '$app/state';
	import { replaceState } from '$app/navigation';

	type R = { id: number; agent: string; repo: string; branch: string; base: string; title: string; status: string;
		rev: number; adds: number; dels: number; files: number; open_comments: number; created_at: string; updated_at: string;
		rev_at: string; task_path: string | null; decided_by: string | null };
	let rows = $state<R[]>([]);
	let error = $state('');
	// sort, direction, filter and the merged/closed toggle live in the URL (?sort=files&dir=desc&q=...&closed=1),
	// so a view can be bookmarked and shared, and survives reloads (guy, 11-13)
	const sp = page.url.searchParams;
	let showClosed = $state(sp.get('closed') === '1');
	let q = $state(sp.get('q') ?? '');
	$effect(() => {
		const f = showClosed ? '' : '&status=in.(open,approved,changes)';
		api<R[]>(`/reviews?select=id,agent,repo,branch,base,title,status,rev,adds,dels,files,open_comments,created_at,updated_at,rev_at,task_path,decided_by${f}`)
			.then((r) => (rows = r.data)).catch((e) => (error = e.message));
	});

	// sortable columns (click a header; again = reverse). Remembered per browser.
	type Key = keyof R | 'size';
	const cols: { key: Key; label: string; num?: boolean; title?: string }[] = [
		{ key: 'id', label: '#', num: true },
		{ key: 'title', label: 'Title' },
		{ key: 'status', label: 'Status' },
		{ key: 'files', label: 'Files', num: true },
		{ key: 'adds', label: '+', num: true, title: 'lines added' },
		{ key: 'dels', label: '−', num: true, title: 'lines removed' },
		{ key: 'size', label: 'Size', num: true, title: 'lines added + removed' },
		{ key: 'open_comments', label: '💬', num: true, title: 'open comments' },
		{ key: 'agent', label: 'Agent' },
		{ key: 'repo', label: 'Project' },
		{ key: 'branch', label: 'Branch' },
		{ key: 'task_path', label: 'Task' },
		{ key: 'rev', label: 'Rev', num: true, title: 'revisions submitted' },
		{ key: 'created_at', label: 'Created' },
		{ key: 'rev_at', label: 'Pushed', title: 'last revision submitted' },
		{ key: 'updated_at', label: 'Updated' },
	];
	const sortParam = sp.get('sort') as Key | null;
	let sortKey = $state<Key>(sortParam && cols.some((c) => c.key === sortParam) ? sortParam : 'updated_at');
	let desc = $state(sp.get('dir') !== 'asc');
	// keep the URL in step (replaceState: no history entry per click or keystroke)
	$effect(() => {
		const u = new URLSearchParams();
		if (sortKey !== 'updated_at') u.set('sort', String(sortKey));
		if (!desc) u.set('dir', 'asc');
		if (q.trim()) u.set('q', q.trim());
		if (showClosed) u.set('closed', '1');
		const next = u.toString() ? `?${u}` : '';
		// shallow: updates the address bar only (no navigation, so the filter box keeps focus while typing)
		if (next !== location.search) replaceState(`/reviews${next}`, {});
	});
	function sortBy(k: Key) {
		if (sortKey === k) desc = !desc; else { sortKey = k; desc = cols.find((c) => c.key === k)?.num || /_at$/.test(String(k)) ? true : false; }
	}
	const order: Record<string, number> = { open: 0, changes: 1, approved: 2, merged: 3, closed: 4 };
	const val = (r: R, k: Key): string | number =>
		k === 'size' ? r.adds + r.dels : k === 'status' ? order[r.status] ?? 9 : k === 'task_path' ? (r.task_path ?? '') : (r[k] as string | number) ?? '';
	const shown = $derived.by(() => {
		const needle = q.trim().toLowerCase();
		const f = needle ? rows.filter((r) => [r.title, r.agent, r.repo, r.branch, r.task_path ?? '', String(r.id), r.status].join(' ').toLowerCase().includes(needle)) : rows;
		return [...f].sort((a, b) => {
			const x = val(a, sortKey), y = val(b, sortKey);
			const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), undefined, { numeric: true });
			return desc ? -c : c;
		});
	});
	const label: Record<string, string> = { open: 'to review', approved: 'approved', changes: 'changes', merged: 'merged', closed: 'closed' };
	const totals = $derived({ n: shown.length, files: shown.reduce((s, r) => s + r.files, 0), adds: shown.reduce((s, r) => s + r.adds, 0),
		dels: shown.reduce((s, r) => s + r.dels, 0) });
</script>

<h1>Code reviews</h1>
<p class="muted small">Agents commit to a branch and submit it with <code>board review submit</code>. Click a review to read the diff,
	comment on lines, and approve (the agent merges and pushes) or request changes. Click a column header to sort.</p>
<div class="bar">
	<input type="search" placeholder="filter: title, agent, project, branch, task…" bind:value={q} />
	<label class="small"><input type="checkbox" bind:checked={showClosed} /> include merged / closed</label>
	<span class="muted small">{totals.n} review{totals.n === 1 ? '' : 's'} · {totals.files} files · <span class="plus">+{totals.adds}</span> <span class="minus">−{totals.dels}</span></span>
</div>
{#if error}<p class="error">{error}</p>{/if}
<div class="wrap panel">
	<table>
		<thead>
			<tr>
				{#each cols as c}
					<th class:num={c.num} title={c.title ?? `sort by ${c.label}`} onclick={() => sortBy(c.key)}
						aria-sort={sortKey === c.key ? (desc ? 'descending' : 'ascending') : 'none'}>
						{c.label}{#if sortKey === c.key}<span class="arrow">{desc ? ' ▼' : ' ▲'}</span>{/if}
					</th>
				{/each}
			</tr>
		</thead>
		<tbody>
			{#each shown as r (r.id)}
				<tr>
					<td class="num"><a href="/reviews/{r.id}">{r.id}</a></td>
					<td class="title"><a href="/reviews/{r.id}">{r.title}</a></td>
					<td><span class="badge s-{r.status}">{label[r.status]}</span></td>
					<td class="num">{r.files}</td>
					<td class="num plus">+{r.adds}</td>
					<td class="num minus">−{r.dels}</td>
					<td class="num">{r.adds + r.dels}</td>
					<td class="num">{r.open_comments || ''}</td>
					<td>{r.agent}</td>
					<td class="mono wrapc">{r.repo}</td>
					<td class="mono wrapc">{r.branch} → {r.base}</td>
					<td>{#if r.task_path}<a href="/tasks/{r.task_path}">#{r.task_path}</a>{/if}</td>
					<td class="num">{r.rev}</td>
					<td title={fmtTime(r.created_at)}>{ago(r.created_at)}</td>
					<td title={fmtTime(r.rev_at)}>{ago(r.rev_at)}</td>
					<td title={fmtTime(r.updated_at)}>{ago(r.updated_at)}</td>
				</tr>
			{:else}
				<tr><td colspan={cols.length} class="muted">No reviews{q ? ' match the filter' : showClosed ? '' : ' waiting'}.</td></tr>
			{/each}
		</tbody>
	</table>
</div>

<style>
	.small { font-size: 0.8rem; }
	.bar { display: flex; flex-wrap: wrap; gap: 0.6rem 1rem; align-items: center; margin: 0.6rem 0; }
	.bar input[type='search'] { flex: 1 1 16rem; max-width: 28rem; }
	.wrap { overflow-x: auto; padding: 0; }
	table { border-collapse: collapse; width: 100%; font-size: 0.82rem; }
	th, td { padding: 0.3rem 0.4rem; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; white-space: nowrap; }
	th { cursor: pointer; user-select: none; position: sticky; top: 0; background: color-mix(in srgb, var(--line) 40%, var(--bg, #fff)); }
	th:hover { text-decoration: underline; }
	.num { text-align: right; font-variant-numeric: tabular-nums; }
	td.title { white-space: normal; min-width: 12rem; }
	td.wrapc { white-space: normal; overflow-wrap: anywhere; min-width: 6rem; }
	th, td { font-size: 0.8rem; }
	.arrow { font-size: 0.7em; }
	tbody tr:hover td { background: color-mix(in srgb, var(--line) 25%, transparent); }
	.plus { color: #1a7f37; } .minus { color: #cf222e; }
	.badge { padding: 0.05rem 0.45rem; border-radius: 999px; font-size: 0.72rem; border: 1px solid var(--line); }
	.s-open { background: #fff4d6; color: #7a5200; } .s-approved { background: #dafbe1; color: #1a7f37; }
	.s-changes { background: #ffebe9; color: #a40e26; } .s-merged { background: #ece4ff; color: #5a32a3; }
</style>
