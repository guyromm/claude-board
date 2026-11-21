// "Sign in with auth.webgma.co.il" (#275/5, doc:auth-integration). The UI is client-rendered (ssr = false), so only
// the /auth/* routes need the server-side session: /auth/token hands the 15-min auth token to the browser.
import { authenticate } from '#lib/server/auth.js';

export const handle = async ({ event, resolve }: { event: any; resolve: (e: any) => Promise<Response> }) => {
	event.locals.auth = null;
	if (event.url.pathname.startsWith('/auth/')) await authenticate(event);
	return resolve(event);
};
