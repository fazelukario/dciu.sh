#!/usr/bin/env sh

# Discord notify module for dciu.sh

# Required:
#DISCORD_WEBHOOK_URL=""
# Optional:
#DISCORD_USERNAME=""
#DISCORD_AVATAR_URL=""

discord_send() {
  # Arguments: event, container name, image, old digest, new digest, mode, running state, message
  event="$1"
  container="$2"
  image="$3"
  old_digest="$4"
  new_digest="$5"
  mode="$6"
  running="$7"
  message="$8"

  # Ensure webhook URL is set
  if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    _err "You didn't specify a Discord webhook url DISCORD_WEBHOOK_URL yet."
    return 1
  fi

  # Compute accent color based on event type
  case "$event" in
    update_available) color=16776960 ;; # yellow
    updated) color=65280 ;;             # green
    update_failed) color=16711680 ;;    # red
    update_skipped) color=8421504 ;;    # grey
    check_failed) color=16753920 ;;     # orange
    *) color=0 ;;                       # default
  esac

  # ISO8601 UTC timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Escape dynamic values
  evt=$(_escape_json "$event")
  cn=$(_escape_json "$container")
  img=$(_escape_json "$image")
  od=$(_escape_json "${old_digest:-unknown}")
  nd=$(_escape_json "${new_digest:-unknown}")
  rn=$(_escape_json "$running")
  md=$(_escape_json "$mode")
  msg=$(_escape_json "$message")
  ts=$(_escape_json "$timestamp")
  src=$(_escape_json "$NOTIFY_SOURCE")

  # Build optional fields
  username_field=""
  avatar_field=""
  if [ -n "$DISCORD_USERNAME" ]; then
    username_field=",\"username\":\"$(_escape_json "$DISCORD_USERNAME")\""
    _debug2 "username_field" "$username_field"
  fi
  if [ -n "$DISCORD_AVATAR_URL" ]; then
    avatar_field=",\"avatar_url\":\"$(_escape_json "$DISCORD_AVATAR_URL")\""
    _debug2 "avatar_field" "$avatar_field"
  fi

  button_url=$(_escape_json "$IMAGE_REGISTRY_URL")

  _debug "button_url" "$button_url"

  # Build payload with Container and Components V2
  payload=$(
    cat << EOF
{
  "flags": 32768${username_field}${avatar_field},
  "components": [
    {
      "type": 17,
      "accent_color": $color,
      "components": [
        {
          "type": 10,
          "content": "# dciu.sh: $evt"
        },
        {
          "type": 10,
          "content": "## :package: Container: $cn"
        },
        {
          "type": 10,
          "content": "### :cd: Image: $img"
        },
        {
          "type": 14,
          "divider": false,
          "spacing": 1
        },
        {
          "type": 10,
          "content": "Old Digest: \`$od\`"
        },
        {
          "type": 10,
          "content": ":arrow_down:"
        },
        {
          "type": 10,
          "content": "New Digest: \`$nd\`"
        },
        {
          "type": 14,
          "divider": false,
          "spacing": 1
        },
        {
          "type": 10,
          "content": ":man_running_facing_right: Running: $rn"
        },
        {
          "type": 10,
          "content": ":gear: Mode: $md"
        },
        {
          "type": 14,
          "divider": true,
          "spacing": 2
        },
        {
          "type": 10,
          "content": "### :clipboard: Message:\n$msg"
        },
        {
          "type": 14,
          "divider": true,
          "spacing": 1
        },
        {
          "type": 1,
          "components": [
            {
              "type": 2,
              "style": 5,
              "label": "View on Docker Hub 🐳",
              "url": "$button_url"
            }
          ]
        },
        {
          "type": 10,
          "content": "-# :alarm_clock: $ts | :desktop: Source: $src"
        }
      ]
    }
  ]
}
EOF
  )

  _debug2 "payload" "$payload"

  # Send to Discord webhook with components V2 enabled (the URL may have a query already, e.g. ?thread_id=...)
  case "$DISCORD_WEBHOOK_URL" in
    *\?*) sep='&' ;;
    *) sep='?' ;;
  esac
  webhook_url="$DISCORD_WEBHOOK_URL${sep}wait=true&with_components=true"
  _secure_debug "webhook_url" "$webhook_url"

  if ! response="$(_post "$payload" "$webhook_url" "" "POST" "application/json")"; then
    _err "Failed to send Discord notification"
    return 1
  fi
  status_code="$(_http_status)"
  # an error page may echo the request URL, which carries the webhook token
  webhook_token="${DISCORD_WEBHOOK_URL##*/}"
  response="$(_hide_secret "$response" "${webhook_token%%\?*}")"
  _debug "status_code" "$status_code"
  _debug2 "response" "$response"

  case "$status_code" in
    2[0-9][0-9]) return 0 ;;
  esac
  _err "Failed to send Discord notification, HTTP status: $status_code"
  [ -z "$response" ] || _err "$response"
  return 1
}
