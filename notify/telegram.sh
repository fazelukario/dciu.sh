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
    _err "You didn't specify a Telegram BOT API Token TELEGRAM_BOT_APITOKEN yet."
    return 1
  fi
  if [ -z "$TELEGRAM_BOT_CHATID" ]; then
    _err "You didn't specify a Telegram Chat id TELEGRAM_BOT_CHATID yet."
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
  od=$(escape_markdown "${old_digest:-unknown}")
  nd=$(escape_markdown "${new_digest:-unknown}")
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

  _debug2 "text" "$text"

  button_url=$(_escape_json "$IMAGE_REGISTRY_URL")

  _debug "button_url" "$button_url"

  # build inline keyboard JSON
  reply_markup=$(
    cat << EOF
{"inline_keyboard":[[{"text":"View on Docker Hub 🐳","url":"$button_url"}]]}
EOF
  )

  _debug2 "reply_markup" "$reply_markup"

  # build JSON payload
  payload=$(
    cat << EOF
{
  "chat_id":"$(_escape_json "$TELEGRAM_BOT_CHATID")",
  "text":"$(_escape_json "$text")",
  "parse_mode":"MarkdownV2",
  "reply_markup":$reply_markup
}
EOF
  )

  _debug2 "payload" "$payload"

  bot_api_url="$TELEGRAM_BOT_URLBASE/bot$TELEGRAM_BOT_APITOKEN/sendMessage"
  _secure_debug "bot_api_url" "$bot_api_url"

  # send the message
  if ! response="$(_post "$payload" "$bot_api_url" "" "POST" "application/json")"; then
    _err "Failed to send Telegram notification"
    return 1
  fi
  status_code="$(_http_status)"
  # an error page may echo the request URL, which carries the bot token
  response="$(_hide_secret "$response" "$TELEGRAM_BOT_APITOKEN")"
  _debug "status_code" "$status_code"
  _debug2 "response" "$response"

  case "$status_code" in
    2[0-9][0-9]) return 0 ;;
  esac
  _err "Failed to send Telegram notification, HTTP status: $status_code"
  [ -z "$response" ] || _err "$response"
  return 1
}
