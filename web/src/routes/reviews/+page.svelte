<script lang="ts">
	import { api, ago } from '#lib/api.svelte.ts';

	type R = { id: number; agent: string; repo: string; branch: string; base: string; title: string; status: string;
		rev: number; adds: number; dels: number; files: number; open_comments: number; updated_at: string; rev_at: string; task_path: string | null };
	let rows = $state<R[]>([]);
	let error = $state('');
	let showClosed = $state(false);
	$effect(() => {
		const q = showClosed ? '' : '&status=in.(open,approved,changes)';
		api<R[]>(`/reviews?select=id,agent,repo,branch,base,title,status,rev,adds,dels,files,open_comments,updated_at,rev_at,task_path&order=updated_at.desc${q}`)
			.then((r) => (rows = r.data)).catch((e) => (error = e.message));
	});
	const label: Record<string, string> = { open: 'to review', approved: 'approved, merging', changes: 'changes requested', merged: 'merged', closed: 'closed' };
	const order = ['open', 'changes', 'approved', 'merged', 'closed'];
	const groups = $derived(order.map((s) => ({ s, items: rows.filter((r) => r.status === s) })).filter((g) => g.items.length));
</script>

<h1>Code reviews</h1>
<p class="muted small">Agents commit their work to a branch and submit it with <code>board review submit</code>. Open one to read the
	diff, comment on any line or selection, and approve (the agent merges and pushes) or request changes.
	<button class="link" onclick={() => (showClosed = !showClosed)}>{showClosed ? 'hide' : 'show'} merged/closed</button></p>
{#if error}<p class="error">{error}</p>{/if}
{#if !rows.length && !error}<p class="muted">No reviews {showClosed ? '' : 'waiting'}.</p>{/if}
{#each groups as g}
	<h2>{label[g.s]} <span class="muted">({g.items.length})</span></h2>
	<ul class="list">
		{#each g.items as r}
			<li class="panel">
				<a href="/reviews/{r.id}"><b>{r.title}</b></a>
				<div class="muted small">
					#{r.id} · {r.agent} · <span class="mono">{r.repo}:{r.branch} → {r.base}</span> · rev {r.rev} ·
					{r.files} file{r.files === 1 ? '' : 's'} <span class="plus">+{r.adds}</span> <span class="minus">−{r.dels}</span>
					{#if r.open_comments} · {r.open_comments} open comment{r.open_comments === 1 ? '' : 's'}{/if}
					· {ago(r.rev_at)}{#if r.task_path} · <a href="/tasks/{r.task_path}">#{r.task_path}</a>{/if}
				</div>
			</li>
		{/each}
	</ul>
{/each}

<style>
	.small { font-size: 0.8rem; }
	.list { list-style: none; padding: 0; display: grid; gap: 0.4rem; }
	.list li { padding: 0.5rem 0.8rem; }
	h2 { font-size: 1rem; margin-top: 1.1rem; text-transform: capitalize; }
	.plus { color: #1a7f37; } .minus { color: #cf222e; }
</style>
