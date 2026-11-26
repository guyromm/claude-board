<script lang="ts">
	import { page } from '$app/state';
	import ReviewView from '#lib/ReviewView.svelte';
	const id = $derived(Number(page.params.id));
</script>

<p><a href="/reviews">← Code reviews</a></p>
{#key id}<ReviewView {id} />{/key}
