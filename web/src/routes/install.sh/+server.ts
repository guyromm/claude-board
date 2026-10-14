import { clientFile, TEXT_HEADERS } from '#lib/server/client.ts';
import type { RequestHandler } from './$types';

// curl -fsSL https://BOARD/install.sh | bash
export const GET: RequestHandler = async ({ url }) =>
	new Response(await clientFile('install.sh', url.origin), { headers: TEXT_HEADERS });
