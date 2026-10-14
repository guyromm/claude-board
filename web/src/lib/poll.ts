// Run `fn` every `ms` while the tab is visible, and once immediately when it becomes visible again.
// Returns a cleanup function, so it can be returned straight from an $effect.
export function every(ms: number, fn: () => void): () => void {
	const tick = () => {
		if (document.visibilityState === 'visible') fn();
	};
	const timer = setInterval(tick, ms);
	document.addEventListener('visibilitychange', tick);
	return () => {
		clearInterval(timer);
		document.removeEventListener('visibilitychange', tick);
	};
}

export const REFRESH_MS = 15_000;
