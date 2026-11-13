import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig, searchForWorkspaceRoot } from 'vite';

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
				// (and claude-ui, mounted at /claude: its component is legacy-mode Svelte)
				runes: ({ filename }) =>
					filename.split(/[/\\]/).some((p) => p === 'node_modules' || p === 'claude-ui')
						? undefined
						: true
			},
			// adapter-node: ui-prod (tmux.sh) runs `node build`; the live ui worker is the vite dev server
			adapter: adapter()
		})
	],
	server: {
		// the dev server is what nginx serves publicly at PUBLIC_ORIGIN (see tmux.sh WORKERS[ui])
		allowedHosts: publicHosts(),
		// claude-ui (../claude-ui/web) sits outside web/; let the dev server read it
		// doc:vite-hardening R3/R4 (#222): minimal allow list; deny secrets, dotdirs and system paths
		fs: {
			strict: true,
			allow: [searchForWorkspaceRoot(process.cwd()), '../claude-ui'],
			deny: ['.env', '.env.*', '*.{pem,crt,key,p12,pfx}', '**/.git/**', '**/.ssh/**', '**/id_rsa*', '**/.npmrc',
				'**/.aws/**', '**/.config/**', '/proc/**', '/sys/**', '/etc/**', '/root/**', '/var/log/**']
		}
	}
});
