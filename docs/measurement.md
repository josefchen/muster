# Measuring Muster's launch

The website counts page loads, download-link clicks and successful Homebrew command copies. The app sends no analytics. These numbers measure distribution; they do not establish installations, active users or retention.

## Read the counts

In Cloudflare, open **D1 → muster-gtm → Console** and run:

```sql
SELECT day, channel, page, event, total
FROM daily_events
ORDER BY day DESC, channel, page, event;
```

The database is private to the Cloudflare account. Export the result as JSON, then generate a report with GitHub downloads and repository traffic:

```sh
python3 scripts/gtm.py --metrics metrics.json --effort docs/gtm-effort.csv
```

Run this weekly. GitHub exposes only 14 days of repository traffic, so save the JSON snapshots if you want a longer history:

```sh
python3 scripts/gtm.py --metrics metrics.json --effort docs/gtm-effort.csv --snapshot-dir ./gtm-snapshots
```

The report covers the preceding seven completed UTC days by default. Use `--days 14` for a longer window. Record actual channel effort and cash costs in the CSV; leave unknown values blank. `--hourly-rate 50` adds an explicit USD cost assumption for your time. Without that argument the report keeps cash and hours separate.

## What to compare

Compare channels by landing-page loads, download clicks, successful Homebrew copies and effort per download click. A click is an expression of interest, not proof of a completed download. Repeated clicks, bots, blockers and privacy preferences affect the counts. GitHub DMG downloads include updates and repeated downloads. Stars show interest, not active use.

Use `?utm_source=console` or another supported source on new campaign links. Recognized sources are `hn`, `hacker-news`, `hackernews`, `github`, `devhunt`, `alternativeto`, `macmenubar`, `betalist`, `console`, `reddit` and `linkedin`. Other values are reduced to `other`. Campaign names, full URLs and referrer strings are never stored.

Attribution lasts only for the current page. Internal navigation is counted as `internal`; there is no visitor ID or cross-page campaign storage. A console email can produce direct traffic if the mail client removes referral information, so campaign links help. Do not compare these counts as unique-person conversion rates.

## Privacy and retention

The database contains daily sums, not individual events. The endpoint accepts only three enumerated labels: `page`, `channel` and `event`. It rejects additional fields. No IP, user-agent, prompt, command, path, repository or personal contact data is written to the measurement database. Both the browser and server honor DNT and GPC. The hourly job deletes totals older than 90 days and refreshes the public GitHub star count.

Worker request logging and Logpush are disabled. Cloudflare still processes network requests to serve and protect the site; that infrastructure processing is separate from these counters. D1 is provisioned with EU jurisdiction.

Learn about activation and retention through volunteers until there is a concrete need for opt-in app reporting. Any future app reporting needs a separate design, a clear choice, and an updated privacy statement.

## Deployment

`scripts/site.sh deploy` builds the complete static asset set and deploys the Worker and www redirect. Use Wrangler 4.151.0 or later. For a fresh account, create the D1 database, update its ID in `site/wrangler.jsonc`, and apply `site/migrations/0001_metrics.sql` before deploying.

```sh
npx wrangler d1 migrations apply muster-gtm --remote --config site/wrangler.jsonc
```

The public site serves `/api/stars`; aggregate acquisition counts have no public read endpoint. Stars are fetched server-side hourly, so visitors make no additional request to GitHub to see the count. If GitHub is unavailable, the last successful count remains available.
