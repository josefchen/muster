(() => {
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1' || navigator.globalPrivacyControl) return;
  const pages = { '/': 'home', '/changelog': 'changelog', '/changelog.html': 'changelog', '/guides/claude-code-notifications-mac': 'claude-code-notifications', '/guides/claude-code-notifications-mac.html': 'claude-code-notifications' };
  const page = pages[location.pathname];
  if (!page) return;
  const sources = { hn: 'hacker-news', hackernews: 'hacker-news', 'hacker-news': 'hacker-news', github: 'github', devhunt: 'devhunt', alternativeto: 'alternativeto', macmenubar: 'macmenubar', betalist: 'betalist', console: 'console', reddit: 'reddit', linkedin: 'linkedin' };
  const hosts = { 'news.ycombinator.com': 'hacker-news', 'github.com': 'github', 'devhunt.org': 'devhunt', 'alternativeto.net': 'alternativeto', 'macmenubar.com': 'macmenubar', 'betalist.com': 'betalist', 'console.dev': 'console', 'reddit.com': 'reddit', 'linkedin.com': 'linkedin' };
  let channel = 'direct';
  const source = new URL(location.href).searchParams.get('utm_source');
  if (source) channel = Object.hasOwn(sources, source.toLowerCase()) ? sources[source.toLowerCase()] : 'other';
  else if (document.referrer) {
    try {
      const referrer = new URL(document.referrer);
      const host = referrer.hostname.replace(/^www\./, '');
      channel = referrer.origin === location.origin ? 'internal' : hosts[host] || 'other';
    } catch { channel = 'other'; }
  }
  const send = event => {
    fetch('/api/metrics', { method: 'POST', body: JSON.stringify({ event, channel, page }),
      headers: { 'Content-Type': 'application/json' }, credentials: 'omit', referrerPolicy: 'no-referrer', keepalive: true }).catch(() => {});
  };
  send('pageview');
  document.addEventListener('click', event => {
    const link = event.target.closest?.('a');
    if (link?.href === 'https://github.com/josefchen/muster/releases/latest/download/Muster.dmg') send('download');
  });
  document.addEventListener('muster:brew-copied', () => send('brew-copy'));
})();
