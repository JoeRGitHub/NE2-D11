#!/usr/bin/env bash
set -euo pipefail

RUNS_PER_SERVER=3
MAX_SERVERS=3

command -v speedtest >/dev/null || { echo "speedtest not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

TMPDIR_DATA="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DATA"' EXIT

RESULTS_FILE="$TMPDIR_DATA/results.jsonl"
: > "$RESULTS_FILE"

echo "Getting nearest $MAX_SERVERS servers..."
speedtest --accept-license --accept-gdpr --servers 2>/dev/null \
  | tee "$TMPDIR_DATA/servers.txt"

awk '/^[[:space:]]*[0-9]+[[:space:]]/ { print $1 }' "$TMPDIR_DATA/servers.txt" \
  | head -n "$MAX_SERVERS" \
  | while read -r SID; do
      echo
      echo "===== Testing server $SID ====="

      OUTFILE="$TMPDIR_DATA/$SID.jsonl"
      ERRFILE="$TMPDIR_DATA/$SID.err"
      : > "$OUTFILE"
      : > "$ERRFILE"

      for i in $(seq 1 "$RUNS_PER_SERVER"); do
        echo "Run $i/$RUNS_PER_SERVER for server $SID..."
        if speedtest --accept-license --accept-gdpr --server-id="$SID" --format=json >> "$OUTFILE" 2>>"$ERRFILE"; then
          :
        else
          echo "Run failed for server $SID"
        fi
      done

      CLEANFILE="$TMPDIR_DATA/$SID.clean.jsonl"
      jq -c '
        select(
          (.download.bandwidth? != null) and
          (.upload.bandwidth? != null) and
          (.ping.latency? != null) and
          (.server.id? != null)
        )
      ' "$OUTFILE" > "$CLEANFILE" || true

      if [ "$(wc -l < "$CLEANFILE")" -lt 2 ]; then
        echo "Not enough successful runs for server $SID"
        echo "Saved raw output: $OUTFILE"
        echo "Saved errors:     $ERRFILE"
        continue
      fi

      jq -s '
        def mean(arr): (arr | add / length);
        def stddev(arr):
          (mean(arr) as $m
          | ((arr | map((. - $m) * (. - $m)) | add) / length) | sqrt);

        {
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
      ' "$CLEANFILE" >> "$RESULTS_FILE"
    done

if [ ! -s "$RESULTS_FILE" ]; then
  echo
  echo "No valid results were collected."
  exit 1
fi

echo
echo "===== Ranked servers ====="
jq -s 'sort_by(-.reliability_score)' "$RESULTS_FILE" | tee "$TMPDIR_DATA/final.json"

echo
echo "===== Best server ====="
jq '.[0]' "$TMPDIR_DATA/final.json"