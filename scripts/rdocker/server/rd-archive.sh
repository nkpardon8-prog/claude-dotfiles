#!/bin/bash
# rd-archive: daily copy of the fleet dashboard's data (1-min history, alerts, leaks, runs) onto the
# home machine, kept forever as ~/rr/archive/YYYY/YYYY-MM-DD.json.gz. Cloudflare keeps 90 days; this
# keeps everything, off the cloud. Runs as the service user from rd-archive.timer (00:20 UTC); fetches
# the last 7 finished UTC days and skips days already on disk, so a missed night backfills itself.
# Needs ~/.config/rdocker/archive-token (0600, = the Worker's ARCHIVE_TOKEN secret).
set -u
CFG=${RD_ARCHIVE_CFG:-$HOME/.config/rdocker}
OUT=${RD_ARCHIVE_DIR:-$HOME/rr/archive}
CURL=${RD_ARCHIVE_CURL:-curl}
DAYS=${RD_ARCHIVE_DAYS:-7}
TOKEN_FILE="$CFG/archive-token"
[ -r "$TOKEN_FILE" ] || { echo "rd-archive: no $TOKEN_FILE yet; nothing to fetch"; exit 0; }
BASE=${RD_ARCHIVE_URL:-$(python3 -c 'import json,sys; u=json.load(open(sys.argv[1]))["url"]; print(u.replace("wss://","https://").replace("ws://","http://").rsplit("/ingest",1)[0])' "$CFG/reporter.json" 2>/dev/null)}
[ -n "$BASE" ] || { echo "rd-archive: no dashboard url (reporter.json)"; exit 1; }
umask 077
fail=0
for n in $(seq 1 "$DAYS"); do
  day=$(date -u -d "-$n day" +%F 2>/dev/null || date -u -v-"$n"d +%F)
  dest="$OUT/${day%%-*}/$day.json.gz"
  [ -s "$dest" ] && continue
  mkdir -p "$(dirname "$dest")"
  tmp="$dest.part"
  if "$CURL" -fsS --max-time 120 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" "$BASE/api/archive?day=$day" | gzip -9 > "$tmp" \
     && [ "$(gzip -dc "$tmp" | head -c 1)" = "{" ]; then
    mv -f "$tmp" "$dest"; echo "rd-archive: saved $day ($(du -h "$dest" | cut -f1))"
  else
    rm -f "$tmp"; echo "rd-archive: $day failed, retrying next run"; fail=1
  fi
done
exit $fail
