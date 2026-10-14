import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { error } from '@sveltejs/kit';
import { CLIENT_DIR, clientFile, TEXT_HEADERS } from '#lib/server/client.ts';
import type { RequestHandler } from './$types';

const FILES = new Set(['board', 'board-watch.sh', 'install.sh']);

export const GET: RequestHandler = async ({ params, url }) => {
	// the watcher's self-upgrade check: WATCH_VERSION of the current board-watch.sh
	if (params.file === 'version') {
		const src = await readFile(resolve(CLIENT_DIR, 'board-watch.sh'), 'utf8');
		return new Response(`${/^WATCH_VERSION=(\d+)/m.exec(src)?.[1] ?? 0}\n`, { headers: TEXT_HEADERS });
	}
	if (!FILES.has(params.file)) error(404, 'not found');
	return new Response(await clientFile(params.file, url.origin), { headers: TEXT_HEADERS });
};
