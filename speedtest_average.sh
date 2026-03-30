#!/usr/bin/env bash
set -euo pipefail

printf "Enter server ID: "
read -r SID

for i in 1 2 3; do
  echo "Running test $i/3 against server $SID..." >&2
  speedtest --accept-license --accept-gdpr --server-id="$SID" --format=json 2>/dev/null || true
done | jq -sr '
  map(
    select(
      .type == "result" and
      (.download.bandwidth? != null) and
      (.upload.bandwidth? != null) and
      (.ping.latency? != null)
    )
  ) as $ok

  | ($ok | length) as $n
  | if $n == 0 then
      error("No successful test results returned")
    else
      (["Run","Time","Download_Mbps","Upload_Mbps","Ping_ms"] | @tsv),

      ($ok | to_entries[] | [
        (.key + 1 | tostring),
        .value.timestamp,
        ((.value.download.bandwidth * 8 / 1000000) | tostring),
        ((.value.upload.bandwidth * 8 / 1000000) | tostring),
        (.value.ping.latency | tostring)
      ] | @tsv),

      ([
        "AVG",
        "-",
        (($ok | map(.download.bandwidth * 8 / 1000000) | add / $n) | tostring),
        (($ok | map(.upload.bandwidth   * 8 / 1000000) | add / $n) | tostring),
        (($ok | map(.ping.latency)                  | add / $n) | tostring)
      ] | @tsv)
    end
' | column -t -s "$(printf '\t')"