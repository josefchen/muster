type SiteRequest = Request<unknown, IncomingRequestCfProperties>;

type MetricEvent = { channel: string; page: string; event: string };
type SiteContent = { index: string; privacy: string; client: string };

export const CHANNELS = new Set(['direct', 'internal', 'hacker-news', 'github', 'devhunt', 'alternativeto', 'macmenubar', 'betalist', 'console', 'reddit', 'linkedin', 'other']);
export const PAGES = new Set(['home', 'changelog', 'claude-code-notifications']);
export const EVENTS = new Set(['pageview', 'download', 'brew-copy']);
const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => Response.json(value, { status, headers: { 'X-Content-Type-Options': 'nosniff', ...headers } });
const empty = () => new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });

async function readEvent(request: Request): Promise<MetricEvent | null> {
  if (request.headers.get('Content-Type')?.split(';')[0].trim().toLowerCase() !== 'application/json') return null;
  if (Number(request.headers.get('Content-Length')) > 256) return null;
  const reader = request.body?.getReader();
  if (!reader) return null;
  let bytes = new Uint8Array(0);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (bytes.length + value.length > 256) { await reader.cancel(); return null; }
      const next = new Uint8Array(bytes.length + value.length);
      next.set(bytes); next.set(value, bytes.length); bytes = next;
    }
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (!parsed || typeof parsed !== 'object') return null;
    const event = parsed as Record<string, unknown>;
    if (!event || Array.isArray(event) || Object.keys(event).sort().join(',') !== 'channel,event,page') return null;
    if (typeof event.channel !== 'string' || typeof event.page !== 'string' || typeof event.event !== 'string') return null;
    if (!CHANNELS.has(event.channel) || !PAGES.has(event.page) || !EVENTS.has(event.event)) return null;
    return { channel: event.channel, page: event.page, event: event.event };
  } catch { return null; }
  finally { reader.releaseLock(); }
}

async function record(request: SiteRequest, env: Env): Promise<Response> {
  if (request.headers.get('Origin') !== new URL(request.url).origin) return new Response(null, { status: 403 });
  if (request.headers.get('DNT') === '1' || request.headers.get('Sec-GPC') === '1' || request.cf?.botManagement?.verifiedBot) return empty();
  const event = await readEvent(request);
  if (!event) return new Response(null, { status: 400 });
  // Only these four dimensions reach storage. No request metadata or raw event log.
  try {
    await env.METRICS.prepare(`INSERT INTO daily_events(day,channel,page,event,total)
      VALUES(date('now'),?,?,?,1) ON CONFLICT(day,channel,page,event) DO UPDATE SET total=total+1`)
      .bind(event.channel, event.page, event.event).run();
    return empty();
  } catch { return new Response(null, { status: 503 }); }
}

export async function refreshStats(env: Env): Promise<void> {
  const response = await fetch('https://api.github.com/repos/josefchen/muster', {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'Muster-website' },
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error('GitHub statistics unavailable');
  const data = await response.json<{ stargazers_count?: unknown }>();
  if (typeof data.stargazers_count !== 'number' || !Number.isSafeInteger(data.stargazers_count) || data.stargazers_count < 0) throw new Error('Invalid star count');
  await env.METRICS.prepare(`INSERT INTO public_stats(key,value,updated_at) VALUES('stars',?,datetime('now'))
    ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at`).bind(data.stargazers_count).run();
}

async function stars(env: Env) {
  try { return await env.METRICS.prepare("SELECT value,updated_at FROM public_stats WHERE key='stars'").first<{ value: number; updated_at: string }>(); }
  catch { return null; }
}

export function createSite({ index, privacy, client }: SiteContent) {
  return {
    async fetch(request: SiteRequest, env: Env): Promise<Response> {
      const url = new URL(request.url);
      if (url.pathname === '/api/metrics') {
        if (request.method !== 'POST') return new Response(null, { status: 405, headers: { Allow: 'POST' } });
        return record(request, env);
      }
      if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
      if (url.pathname === '/api/stars') {
        const response = json(await stars(env), 200, { 'Cache-Control': 'public, max-age=300' });
        return request.method === 'HEAD' ? new Response(null, response) : response;
      }
      if (url.pathname === '/site.js') return new Response(request.method === 'HEAD' ? null : client, {
        headers: { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'public, max-age=3600', 'X-Content-Type-Options': 'nosniff' },
      });
      let response;
      if (url.pathname === '/' || url.pathname === '/privacy') {
        response = new Response(url.pathname === '/' ? index : privacy, { headers: {
          'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=300',
          'Referrer-Policy': 'strict-origin-when-cross-origin', 'X-Content-Type-Options': 'nosniff',
          'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        } });
        if (url.pathname === '/') {
          const stats = await stars(env);
          if (stats && Number.isSafeInteger(stats.value) && stats.value >= 0) response = new HTMLRewriter()
            .on('[data-star-number]', { element(el) { el.setInnerContent(stats.value.toLocaleString('en-US')); } })
            .on('[data-star-count]', { element(el) { el.removeAttribute('hidden'); } }).transform(response);
        }
      } else {
        response = await env.ASSETS.fetch(request);
        if (response.ok && response.headers.get('Content-Type')?.includes('text/html')) response = new HTMLRewriter()
          .on('footer .wrap', { element(el) { el.append('<a href="/privacy">Privacy</a>', { html: true }); } })
          .on('body', { element(el) { el.append('<script src="/site.js" defer></script>', { html: true }); } }).transform(response);
      }
      return request.method === 'HEAD' ? new Response(null, response) : response;
    },
    async scheduled(_event: ScheduledController, env: Env): Promise<void> {
      // Retention continues even if GitHub is temporarily unavailable.
      await env.METRICS.prepare("DELETE FROM daily_events WHERE day <= date('now','-90 days')").run();
      await refreshStats(env);
    },
  };
}
