#!/usr/bin/env bash
set -euo pipefail

RUNS_PER_SERVER=3
MAX_SERVERS=8

command -v speedtest >/dev/null || { echo "speedtest not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

TMPDIR_DATA="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DATA"' EXIT

echo "Getting nearest $MAX_SERVERS servers..."
speedtest servers 2>/dev/null | head -n "$MAX_SERVERS" | tee "$TMPDIR_DATA/servers.txt"

awk -F')' '/^[[:space:]]*[0-9]+\)/ {gsub(/^[[:space:]]+/, "", $1); print $1}' "$TMPDIR_DATA/servers.txt" | while read -r SID; do
  echo
  echo "===== Testing server $SID ====="

  OUTFILE="$TMPDIR_DATA/$SID.jsonl"
  : > "$OUTFILE"

  for i in $(seq 1 "$RUNS_PER_SERVER"); do
    echo "Run $i/$RUNS_PER_SERVER for server $SID..."
    if speedtest --server-id="$SID" --format=json >> "$OUTFILE" 2>/dev/null; then
      :
    else
      echo "Run failed for server $SID"
    fi
  done

  if [ "$(wc -l < "$OUTFILE")" -lt 2 ]; then
    echo "Not enough successful runs for server $SID"
    continue
  fi

  jq -s '
    def mean(arr): (arr | add / length);
    def stddev(arr):
      (mean(arr) as $m
      | ((arr | map((. - $m) * (. - $m)) | add) / length) | sqrt);

    . as $runs
    | {
        server_id: .[0].server.id,
        server_name: .[0].server.name,
        location: .[0].server.location,
        runs: length,
        avg_download_mbps: (mean(map(.download.bandwidth * 8 / 1000000))),
        avg_upload_mbps:   (mean(map(.upload.bandwidth * 8 / 1000000))),
        avg_ping_ms:       (mean(map(.ping.latency))),
        std_download_mbps: (stddev(map(.download.bandwidth * 8 / 1000000))),
        std_upload_mbps:   (stddev(map(.upload.bandwidth * 8 / 1000000))),
        std_ping_ms:       (stddev(map(.ping.latency))),
        reliability_score: (
          1000
          - (stddev(map(.download.bandwidth * 8 / 1000000)) * 8)
          - (stddev(map(.upload.bandwidth * 8 / 1000000)) * 5)
          - (mean(map(.ping.latency)) * 2)
          - (stddev(map(.ping.latency)) * 20)
        )
      }
  ' "$OUTFILE" >> "$TMPDIR_DATA/results.jsonl"
done

echo
echo "===== Ranked servers ====="
jq -s 'sort_by(-.reliability_score)' "$TMPDIR_DATA"/results.jsonl | tee "$TMPDIR_DATA/final.json"

echo
echo "===== Best server ====="
jq '.[0]' "$TMPDIR_DATA/final.json"


# After ruuing 