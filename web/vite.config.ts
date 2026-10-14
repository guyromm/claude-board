import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// PUBLIC_ORIGIN's host and its www. alias (tmux.sh passes PUBLIC_ORIGIN from .env)
function publicHosts(): string[] {
	const origin = process.env.PUBLIC_ORIGIN;
	if (!origin) return [];
	const host = new URL(origin).hostname;
	return [host, `www.${host}`];
}

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// adapter-node: ui-prod (tmux.sh) runs `node build`; the live ui worker is the vite dev server
			adapter: adapter()
		})
	],
	server: {
		// the dev server is what nginx serves publicly at PUBLIC_ORIGIN (see tmux.sh WORKERS[ui])
		allowedHosts: publicHosts()
	}
});
