<script lang="ts">
	import { ago, type ThreadSummary } from '#lib/api.svelte.ts';
	import Md from '#lib/Md.svelte';

	// thread status banner: summarizer's verdict (open/closed, needs human) + the summary text
	let { s }: { s: ThreadSummary | undefined } = $props();
</script>

{#if s?.status}
	<div class="summary" class:human={s.needs_human} class:closed={s.status === 'closed'}>
		<div class="flags">
			<span class="status {s.status}">{s.status === 'open' ? 'Open' : 'Closed'}</span>
			{#if s.needs_human}<span class="attn">Needs you</span>{/if}
			{#if s.stale}<span class="stale" title="new messages since this summary; a re-summary is on its way">updating…</span>{/if}
			<span class="spacer"></span>
			<span class="by" title={s.summarized_at ?? ''}>summary by {s.summarized_by} · through #{s.summarized_through} · {ago(s.summarized_at)}</span>
		</div>
		{#if s.needs_human && s.human_reason}<div class="reason"><b>Your call:</b> <Md text={s.human_reason} /></div>{/if}
		<div class="text"><Md text={s.summary ?? ''} /></div>
	</div>
{:else if s}
	<div class="summary pending"><span class="by">not summarized yet</span></div>
{/if}

<style>
	.summary {
		--tone: var(--accent);
		position: relative; z-index: 1;
		border: 1px solid color-mix(in srgb, var(--tone) 45%, var(--line));
		border-left: 4px solid var(--tone);
		background: color-mix(in srgb, var(--tone) 8%, var(--panel));
		border-radius: 6px; padding: 0.5rem 0.7rem; margin: 0.4rem 0 0.6rem;
		display: grid; gap: 0.3rem; font-size: 0.88rem;
	}
	.summary.closed { --tone: #2e9d5b; }
	.summary.human { --tone: #d9480f; }
	.summary.pending { --tone: var(--line); background: transparent; padding: 0.2rem 0.6rem; }
	.flags { display: flex; gap: 0.4rem; align-items: center; flex-wrap: wrap; }
	.flags > span:not(.spacer):not(.by) {
		font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
		padding: 0.1rem 0.45rem; border-radius: 999px;
	}
	.status.open { background: var(--accent); color: var(--accent-ink); }
	.status.closed { background: #2e9d5b; color: #fff; }
	.attn { background: #d9480f; color: #fff; }
	.stale { border: 1px dashed var(--muted); color: var(--muted); }
	.spacer { flex: 1; }
	.by { color: var(--muted); font-size: 0.75rem; }
	.reason { color: #d9480f; font-weight: 500; }
	.text { overflow-wrap: anywhere; }
</style>
