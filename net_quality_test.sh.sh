#!/bin/sh

LOGFILE="/var/log/net_quality.log"
TEST_HOST1="8.8.8.8"
TEST_HOST2="1.1.1.1"
HTTP_TEST_URL="http://speedtest.tele2.net/1MB.zip"   # or your own small file

TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')

# 1. Ping test (latency & packet loss)
PING1=$(ping -c 5 -w 10 $TEST_HOST1 2>/dev/null | tail -n 2 | tr '\n' ' ')
PING2=$(ping -c 5 -w 10 $TEST_HOST2 2>/dev/null | tail -n 2 | tr '\n' ' ')

# 2. Small HTTP download test (download speed estimate)
# Measure time to download a 1MB file and compute kbps
TMPFILE="/tmp/nettest_$$.bin"
START=$(date +%s%3N 2>/dev/null || date +%s)  # ms if supported, else s
wget -q -O "$TMPFILE" "$HTTP_TEST_URL"
END=$(date +%s%3N 2>/dev/null || date +%s)
rm -f "$TMPFILE"

if [ -f /usr/bin/stat ]; then
  BYTES=$(stat -c%s "$TMPFILE" 2>/dev/null || echo 0)
else
  BYTES=0
fi

DURATION_MS=$((END - START))
if [ "$DURATION_MS" -le 0 ]; then
  DURATION_MS=1
fi

# kbps ≈ (bytes * 8 / 1000) / (duration_s)
KBPS=$(( BYTES * 8 * 1000 / DURATION_MS / 1000 ))

echo "$TIMESTAMP PING1: $PING1 PING2: $PING2 HTTP_KBPS: $KBPS" >> "$LOGFILE"