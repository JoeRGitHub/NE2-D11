# Device:
ne2-d11p

# Check system logs Teltonika:

logread -f

# Check Logstash logs:

docker logs -f <name>

# Check basic connction to Tltonika:

curl -u user:"pass" http://<IP>:<PORT/

# Send data to Elastic with JSON format:

lua lua_sctipt_json_format_login.lua > /tmp/test.json

curl -u user:"pass" -XPOST "http://<IP>:<PORT>/test-lua-index/\_doc" \
 -H 'Content-Type: application/json' \
 -d @/tmp/test.json
