printf "Enter server ID: "
read SID
for i in 1 2 3; do
  echo "Running test $i/3 against server $SID..." >&2
  speedtest --server-id="$SID" --format=json
done | jq -sr '
  (["Run","Time","Download_Mbps","Upload_Mbps","Ping_ms"] | @tsv),
  (to_entries[] | [
      (.key + 1 | tostring),
      .value.timestamp,
      ((.value.download.bandwidth * 8 / 1000000) | tostring),
      ((.value.upload.bandwidth * 8 / 1000000) | tostring),
      (.value.ping.latency | tostring)
    ] | @tsv),
  ([
      "AVG",
      "-",
      ((map(.download.bandwidth * 8) | add / length / 1000000) | tostring),
      ((map(.upload.bandwidth * 8)   | add / length / 1000000) | tostring),
      ((map(.ping.latency)           | add / length) | tostring)
    ] | @tsv)
' | column -t -s $'\t'