#!/usr/bin/env python3
"""Summarize aggregate website counts and GitHub distribution statistics."""
import argparse
import csv
import datetime as dt
import json
import math
from pathlib import Path
import subprocess

REPO = 'josefchen/muster'


def github(path):
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'GitHub request failed for {path}; check gh auth and repository access.')
    return json.loads(result.stdout)


def metric_rows(value):
    if isinstance(value, dict):
        for key in ('results', 'result'):
            if key in value:
                return metric_rows(value[key])
        raise ValueError('Expected a D1 results object or an array of rows.')
    if not isinstance(value, list):
        raise ValueError('Expected an array of aggregate rows.')
    rows = []
    for row in value:
        if isinstance(row, dict) and 'day' in row:
            rows.append(row)
        else:
            rows.extend(metric_rows(row))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metrics', type=Path, required=True, help='D1 JSON export')
    parser.add_argument('--effort', type=Path)
    parser.add_argument('--days', type=int, default=7)
    parser.add_argument('--hourly-rate', type=float, help='Explicit USD value of one hour')
    parser.add_argument('--snapshot-dir', type=Path)
    args = parser.parse_args()
    if not 1 <= args.days <= 90 or (args.hourly_rate is not None and (not math.isfinite(args.hourly_rate) or args.hourly_rate < 0)):
        parser.error('Use 1–90 days and a nonnegative hourly rate.')
    end = dt.datetime.now(dt.timezone.utc).date()
    start = end - dt.timedelta(days=args.days)
    channels = {}
    def bucket(channel):
        return channels.setdefault(channel, {'pageview': 0, 'download': 0, 'brew-copy': 0, 'minutes': 0, 'cash_usd': 0, 'effort_known': False, 'effort_incomplete': False})
    rows = metric_rows(json.loads(args.metrics.read_text()))
    for row in rows:
        day = dt.date.fromisoformat(row['day'])
        if start <= day < end and row['page'] == 'home':
            if row['event'] not in ('pageview', 'download', 'brew-copy'):
                raise ValueError('Unexpected event in aggregate export.')
            total = row['total']
            if not isinstance(total, int) or isinstance(total, bool) or total < 0:
                raise ValueError('Aggregate totals must be nonnegative integers.')
            bucket(row['channel'])[row['event']] += total
    if args.effort:
        with args.effort.open(newline='') as source:
            for row in csv.DictReader(source):
                if start <= dt.date.fromisoformat(row['date']) < end:
                    group = bucket(row['channel'])
                    minutes = float(row['minutes']) if row['minutes'] else None
                    cash = float(row['cash_usd']) if row['cash_usd'] else None
                    if any(value is not None and (not math.isfinite(value) or value < 0) for value in (minutes, cash)):
                        raise ValueError('Effort and cash costs must be nonnegative.')
                    if minutes is None or cash is None:
                        group['effort_incomplete'] = True
                    if minutes is not None and cash is not None:
                        group['effort_known'] = True
                        group['minutes'] += minutes
                        group['cash_usd'] += cash
    repo = github(f'repos/{REPO}')
    releases = github(f'repos/{REPO}/releases?per_page=100')
    downloads = sum(asset['download_count'] for release in releases for asset in release['assets'] if asset['name'] == 'Muster.dmg')
    traffic = github(f'repos/{REPO}/traffic/views')
    referrers = github(f'repos/{REPO}/traffic/popular/referrers')
    print(f'# Muster GTM · {start}–{end - dt.timedelta(days=1)} UTC\n')
    print('| Channel | Landing-page loads | Download clicks | Brew copies | Hours | Cash USD | USD / click |')
    print('|---|---:|---:|---:|---:|---:|---:|')
    for channel, group in sorted(channels.items()):
        hours = group['minutes'] / 60
        cost = group['cash_usd'] + hours * (args.hourly_rate or 0)
        known = group['effort_known'] and not group['effort_incomplete']
        cost_per_click = f"{cost / group['download']:.2f}" if known and group['download'] else '—'
        hours_text = f'{hours:.2f}' if known else '—'
        cash_text = f"{group['cash_usd']:.2f}" if known else '—'
        print(f"| {channel} | {group['pageview']} | {group['download']} | {group['brew-copy']} | {hours_text} | {cash_text} | {cost_per_click} |")
    if not channels:
        print('No completed-day website counts in this window.')
    print(f"\nGitHub snapshot: {repo['stargazers_count']} stars; {downloads} lifetime DMG download requests across the latest 100 releases.")
    print(f"GitHub reports {traffic['count']} repository views and {traffic['uniques']} unique-visitor estimates over its last 14 days.")
    print('These are repository visitors and download requests, not active Muster users. Website counts are events, not unique people.')
    print('Cost per click includes cash only.' if args.hourly_rate is None else f'Cost per click values time at USD {args.hourly_rate:g}/hour, plus cash.')
    print('A dash means costs are unknown or there were no download clicks. Effort rows need both minutes and cash, including explicit zeroes.')
    if args.snapshot_dir:
        args.snapshot_dir.mkdir(parents=True, exist_ok=True)
        snapshot = {'captured_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'website_rows': rows,
                    'github': {'stars': repo['stargazers_count'], 'dmg_downloads': downloads, 'traffic': traffic, 'referrers': referrers}}
        (args.snapshot_dir / f'{end}.json').write_text(json.dumps(snapshot, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        raise SystemExit(str(error)) from error
