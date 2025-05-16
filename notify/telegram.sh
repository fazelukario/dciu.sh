#!/usr/bin/env sh

# Telegram notify module for dciu.sh

# Required:
#TELEGRAM_BOT_APITOKEN=""
#TELEGRAM_BOT_CHATID=""
# Optional:
#TELEGRAM_BOT_URLBASE=""

telegram_send() {
  # Arguments: event, container name, image, old digest, new digest, mode, running state, message
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
    return 1
  fi
  if [ -z "$TELEGRAM_BOT_CHATID" ]; then
    echo "[Error] TELEGRAM_BOT_CHATID is not set" >&2
    return 1
  fi

  # set default API URL if not provided
  if [ -z "$TELEGRAM_BOT_URLBASE" ]; then
    TELEGRAM_BOT_URLBASE="https://api.telegram.org"
  fi

  # function to escape Telegram MarkdownV2 special characters
  escape_markdown() { printf "%s" "$1" | sed 's/\\/\\\\/g' | sed 's/\]/\\\]/g' | sed 's/\([_*[()~`>#+--=|{}.!]\)/\\\1/g'; }

  # escape dynamic values
  evt=$(escape_markdown "$event")
  cn=$(escape_markdown "$container")
  img=$(escape_markdown "$image")
  od=$(escape_markdown "$old_digest")
  nd=$(escape_markdown "$new_digest")
  rn=$(escape_markdown "$running")
  md=$(escape_markdown "$mode")
  msg=$(escape_markdown "$message")
  src=$(escape_markdown "$NOTIFY_SOURCE")

  # build message text with here-doc for POSIX compliance
  text=$(
    cat << EOF
*dciu\\.sh: ${evt}*
*📦 Container:* ${cn}
*💿 Image:* ${img}
*Old Digest:* \`${od}\`
    ⬇
*New Digest:* \`${nd}\`
*🏃‍♂️ Running:* ${rn}
*⚙ Mode:* ${md}
*📋 Message:*
>${msg}
_🖥 Source:_ \`${src}\`
EOF
  )

  _debug "text" "$text"

  button_url=$(escape_json "$IMAGE_REGISTRY_URL")

  _debug "button_url" "$button_url"

  # build inline keyboard JSON
  reply_markup=$(
    cat << EOF
{"inline_keyboard":[[{"text":"View on Docker Hub 🐳","url":"$button_url"}]]}
EOF
  )

  _debug "reply_markup" "$reply_markup"

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

  _debug "payload" "$payload"

  bot_api_url="$TELEGRAM_BOT_URLBASE/bot$TELEGRAM_BOT_APITOKEN/sendMessage"
  _debug "bot_api_url" "$bot_api_url"

  # send the message
  curl -s -w "\n%{http_code}" -X POST "$bot_api_url" \
    -H "Content-Type: application/json" \
    --data "$payload" | {
    _ret="$?"
    read -r response
    read -r status_code
    _debug "status_code" "$status_code"
    _debug "Response:"
    _debug "$response"

    if [ "$_ret" != "0" ]; then
      _err "Please refer to https://curl.haxx.se/libcurl/c/libcurl-errors.html for error code: $_ret"
    fi

    if [ "$status_code" -lt 200 ] || [ "$status_code" -ge 300 ]; then
      _err "[Error] Failed to send Telegram notification, HTTP status: $status_code" >&2
      return 1
    fi
  }

  return 0
}
