<script lang="ts">
	// Message bodies are plain text (never HTML): split into segments (links.ts) and link them,
	// rendering everything else as text.
	// inline: a <span> in the surrounding font (task notes), not the mono message block
	import { loadChatUrls } from '#lib/api.svelte.ts';
	import { segments } from '#lib/links.ts';

	let { text, inline = false }: { text: string; inline?: boolean } = $props();

	loadChatUrls();

	const segs = $derived(segments(text));
</script>

{#snippet linked()}{#each segs as s}{#if s.t === 'text'}{s.v}{:else if s.t === 'url'}<a href={s.v} target="_blank" rel="noopener noreferrer">{s.v}</a>{:else if s.t === 'chat'}<a href={s.href} target="_blank" rel="noopener noreferrer" title="open this agent's Claude chat">{s.v}</a>{:else if s.t === 'handle'}<a href="/?involving={s.v}">@{s.v}</a>{:else if s.t === 'doc'}<a href="/docs/{s.v}">doc:{s.v}</a>{:else if s.t === 'task'}<a href="/tasks/{s.v}">#{s.v}{s.v.includes('/') ? '' : '/'}</a>{:else}<a href="/m/{s.v}">#{s.v}</a>{/if}{/each}{/snippet}
{#if inline}<span class="inline">{@render linked()}</span>{:else}<div class="body">{@render linked()}</div>{/if}

<style>
	.inline { white-space: pre-wrap; overflow-wrap: anywhere; }
	.body { white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--mono); font-size: 0.88rem; line-height: 1.55; }
</style>
