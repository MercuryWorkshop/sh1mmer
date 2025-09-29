#!/bin/bash

if curl -Is https://example.com | head -n 1 | grep -q "HTTP/"; then
    "$@"
else
    echo "Not connected to the internet"
    exit 1
fi

url="https://api.github.com/repos/MercuryWorkshop/sh1mmer"
content_url="${url}/contents/wax/payloads?ref=beautifulworld"

if ! command -v jq &> /dev/null; then
    echo "jq not installed. (why?)" >&2
    exit 1
fi

echo "Finding payloads from $content_url"

mkdir -p ./payloads

response=$(curl -s -H "Accept: application/vnd.github.v3+json" "$content_url")

if echo "$response" | jq -e '.message | type == "string"' > /dev/null 2>&1; then
    error=$(echo "$response" | jq -r '.message')
    echo -e "Github API failed with \"\033[1;31m${error}\033[0m\"" >&2
    exit 1
fi

payloads=$(echo "$response" | jq -r '.[] | select(.type == "file") | .name + " " + .download_url')

if [[ -z "$payloads" ]]; then
    echo "No payloads found."
else
    echo "$payloads" | while read -r filename download_url; do
        echo " - Downloading ${filename}..."
        curl -s -L "$download_url" -o "./payloads/${filename}"
        if [ $? -ne 0 ]; then
            echo -e "\033[1;31m - Could not download ${filename}.\033[0m" >&2
        fi
    done
    echo "Downloaded payloads to ./payloads."
fi

version=sh1mmer_legacy
if [ -f /usr/sbin/sh1mmer_gui.sh ]; then
    version=sh1mmer_bw
fi

date=$(curl -s "${url}/commits?path=wax/${version}/root/noarch/usr/sbin/sh1mmer_main.sh&sha=beautifulworld&per_page=1" | jq -r '.[0].commit.committer.date')

if [[ "$date" == "null" || -z "$date" ]]; then
    echo "Could not find latest commit date."
fi

formatted_date=$(date -d "$date" +%Y-%d-%m)

sed -i "s/SCRIPT_DATE=\"\[.*\]\"/SCRIPT_DATE=\"[${formatted_date}]\"/" /usr/sbin/sh1mmer_main.sh
