#!/usr/bin/env sh

# Telegram notify module for dciu.sh

# Required:
#TELEGRAM_BOT_APITOKEN=""
#TELEGRAM_BOT_CHATID=""
# Optional:
#TELEGRAM_BOT_URLBASE=""

# script arguments: event, container name, image, old digest, new digest, mode, running state, message
event="$1"
container="$2"
image="$3"
old_digest="$4"
new_digest="$5"
mode="$6"
running="$7"
message="$8"

# check required variables
if [ -z "$TELEGRAM_BOT_APITOKEN" ]; then
  echo "[Error] TELEGRAM_BOT_APITOKEN is not set" >&2
  exit 1
fi
if [ -z "$TELEGRAM_BOT_CHATID" ]; then
  echo "[Error] TELEGRAM_BOT_CHATID is not set" >&2
  exit 1
fi

# set default API URL if not provided
if [ -z "$TELEGRAM_BOT_URLBASE" ]; then
  TELEGRAM_BOT_URLBASE="https://api.telegram.org"
fi

# function to escape Telegram MarkdownV2 special characters
escape_markdown() { printf "%s" "$1" | sed 's/\\/\\\\/g' | sed 's/\]/\\\]/g' | sed 's/\([_*[()~`>#+--=|{}.!]\)/\\\1/g'; }

# function to escape JSON strings
escape_json() { printf '%s' "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;s/\n/\\n/g;ta'; }

# escape dynamic values
evt=$(escape_markdown "dciu.sh: $event")
cn=$(escape_markdown "$container")
img=$(escape_markdown "$image")
od=$(escape_markdown "$old_digest")
nd=$(escape_markdown "$new_digest")
rn=$(escape_markdown "$running")
md=$(escape_markdown "$mode")
msg=$(escape_markdown "$message")

# build message text with here-doc for POSIX compliance
text=$(
  cat << EOF
*${evt}*
*📦 Container:* ${cn}
*💿 Image:* ${img}
*Old Digest:* \`${od}\`
    ⬇
*New Digest:* \`${nd}\`
*🏃‍♂️ Running:* ${rn}
*⚙ Mode:* ${md}
*📋 Message:*
>${msg}
EOF
)

# build Docker Hub URL for the image
hub_url="https://hub.docker.com/r/${image%%:*}"
button_url=$(escape_json "$hub_url")

# build inline keyboard JSON
reply_markup=$(
  cat << EOF
{"inline_keyboard":[[{"text":"View on Docker Hub 🐳","url":"$button_url"}]]}
EOF
)

# build JSON payload
payload=$(
  cat << EOF
{
  "chat_id":"$(escape_json "$TELEGRAM_BOT_CHATID")",
  "text":"$(escape_json "$text")",
  "parse_mode":"MarkdownV2",
  "reply_markup":$reply_markup
}
EOF
)

# send the message
status_code=$(
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$TELEGRAM_BOT_URLBASE/bot$TELEGRAM_BOT_APITOKEN/sendMessage" \
    -H "Content-Type: application/json" \
    --data "$payload"
)

if [ "$status_code" -lt 200 ] || [ "$status_code" -ge 300 ]; then
  echo "[Error] Failed to send Telegram notification, HTTP status: $status_code" >&2
  exit 1
fi

exit 0
