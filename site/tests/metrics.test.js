import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { createSite } from '../server.ts';

const site = createSite({ index: '', privacy: 'Privacy', client: '' });
function database() {
  const db = new DatabaseSync(':memory:');
  db.exec(readFileSync(new URL('../migrations/0001_metrics.sql', import.meta.url), 'utf8'));
  return { db, env: { METRICS: { prepare(sql) {
    let args = [];
    const query = { bind(...values) { args = values; return query; },
      async run() { return db.prepare(sql).run(...args); },
      async first() { return db.prepare(sql).get(...args) ?? null; } };
    return query;
  } } } };
}
function request(body, headers = {}) {
  return new Request('https://agentmuster.app/api/metrics', { method: 'POST',
    headers: { Origin: 'https://agentmuster.app', 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
}
const event = { event: 'download', channel: 'hacker-news', page: 'home' };

test('only aggregate counters are retained, including concurrent increments', async () => {
  const { db, env } = database();
  const responses = await Promise.all(Array.from({ length: 8 }, () => site.fetch(request(event), env)));
  assert(responses.every(r => r.status === 204));
  const rows = db.prepare('SELECT * FROM daily_events').all();
  assert.equal(rows.length, 1); assert.equal(rows[0].total, 8);
  assert.deepEqual(Object.keys(rows[0]).sort(), ['channel', 'day', 'event', 'page', 'total']);
  db.close();
});

test('rejects private fields, raw URLs, unknown values and oversized bodies', async () => {
  const { db, env } = database();
  for (const payload of [{ ...event, email: 'test@example.invalid' }, { ...event, page: '/private/project' },
    { ...event, channel: 'https://example.invalid/person' }, { ...event, event: 'prompt' },
    { ...event, prompt: 'x'.repeat(500) }, null, []]) {
    assert.equal((await site.fetch(request(payload), env)).status, 400);
  }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM daily_events').get().n, 0);
  db.close();
});

test('privacy signals and cross-origin requests never increment a counter', async () => {
  const { db, env } = database();
  assert.equal((await site.fetch(request(event, { DNT: '1' }), env)).status, 204);
  assert.equal((await site.fetch(request(event, { 'Sec-GPC': '1' }), env)).status, 204);
  assert.equal((await site.fetch(request(event, { Origin: 'https://example.invalid' }), env)).status, 403);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM daily_events').get().n, 0);
  db.close();
});

test('no public endpoint exposes acquisition counts', async () => {
  const { db, env } = database();
  assert.equal((await site.fetch(new Request('https://agentmuster.app/api/metrics'), env)).status, 405);
  const stars = await site.fetch(new Request('https://agentmuster.app/api/stars'), env);
  assert.equal(await stars.json(), null);
  assert.equal((await site.fetch(new Request('https://agentmuster.app/privacy', { method: 'HEAD' }), env)).status, 200);
  db.close();
});

function browser({ dnt, gpc, source = 'hn', referrer = '' } = {}) {
  const sent = [], listeners = {};
  const context = { navigator: { doNotTrack: dnt, globalPrivacyControl: gpc }, window: {}, URL,
    location: { href: `https://agentmuster.app/?utm_source=${source}`, pathname: '/', origin: 'https://agentmuster.app' },
    document: { referrer, addEventListener(name, fn) { listeners[name] = fn; } },
    fetch(url, options) { sent.push({ url, options }); return Promise.resolve(); } };
  vm.runInNewContext(readFileSync(new URL('../client.js', import.meta.url), 'utf8'), context);
  return { sent, listeners };
}

test('browser suppresses reporting for DNT and GPC', () => {
  assert.equal(browser({ dnt: '1' }).sent.length, 0);
  assert.equal(browser({ gpc: true }).sent.length, 0);
});

test('browser sends coarse dimensions without URL, credentials or referrer', () => {
  const { sent, listeners } = browser({ source: 'someone@example.invalid' });
  listeners.click({ target: { closest: () => ({ href: 'https://github.com/josefchen/muster/releases/latest/download/Muster.dmg' }) } });
  assert.equal(sent.length, 2);
  assert.deepEqual(JSON.parse(sent[0].options.body), { event: 'pageview', channel: 'other', page: 'home' });
  assert.equal(sent[0].options.credentials, 'omit');
  assert.equal(sent[0].options.referrerPolicy, 'no-referrer');
  assert.equal(JSON.parse(sent[1].options.body).event, 'download');
});


test('retention removes expired totals even when the GitHub refresh fails', async () => {
  const { db, env } = database();
  db.exec("INSERT INTO daily_events VALUES(date('now','-90 days'),'direct','home','pageview',1), (date('now','-89 days'),'direct','home','pageview',1)");
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 503 });
  try { await assert.rejects(site.scheduled({}, env), /GitHub statistics unavailable/); }
  finally { globalThis.fetch = originalFetch; }
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM daily_events').get().n, 1);
  db.close();
});
