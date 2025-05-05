#!/usr/bin/env sh

# Discord notify module for dciu.sh

# Required:
#DISCORD_WEBHOOK_URL=""
# Optional:
#DISCORD_USERNAME=""
#DISCORD_AVATAR_URL=""

# Arguments: event, container name, image, old digest, new digest, mode, running state, message
event="$1"
container="$2"
image="$3"
old_digest="$4"
new_digest="$5"
mode="$6"
running="$7"
message="$8"

if [ -n "$DCIU_DISCORD_WEBHOOK_URL" ]; then DISCORD_WEBHOOK_URL="$DCIU_DISCORD_WEBHOOK_URL"; fi
if [ -n "$DCIU_DISCORD_USERNAME" ]; then DISCORD_USERNAME="$DCIU_DISCORD_USERNAME"; fi
if [ -n "$DCIU_DISCORD_AVATAR_URL" ]; then DISCORD_AVATAR_URL="$DCIU_DISCORD_AVATAR_URL"; fi

# Ensure webhook URL is set
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
  echo "[Error] DISCORD_WEBHOOK_URL is not set" >&2
  exit 1
fi

# Compute accent color based on event type
case "$event" in
  update_available) color=16776960 ;; # yellow
  updated) color=65280 ;;             # green
  update_failed) color=16711680 ;;    # red
  update_skipped) color=8421504 ;;    # grey
  *) color=0 ;;                       # default
esac

# ISO8601 UTC timestamp
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Function to escape JSON strings
escape_json() { printf "%s" "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;s/\n/\\n/g;ta'; }

# Escape dynamic values
evt=$(escape_json "$event")
cn=$(escape_json "$container")
img=$(escape_json "$image")
od=$(escape_json "$old_digest")
nd=$(escape_json "$new_digest")
rn=$(escape_json "$running")
md=$(escape_json "$mode")
msg=$(escape_json "$message")
ts=$(escape_json "$timestamp")
src=$(escape_json "$DCIU_NOTIFY_SOURCE")

# Build optional fields
username_field=""
avatar_field=""
if [ -n "$DISCORD_USERNAME" ]; then
  username_field=",\"username\":\"$(escape_json "$DISCORD_USERNAME")\""
fi
if [ -n "$DISCORD_AVATAR_URL" ]; then
  avatar_field=",\"avatar_url\":\"$(escape_json "$DISCORD_AVATAR_URL")\""
fi

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
              "url": "https://hub.docker.com/r/${img%%:*}"
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

# Send to Discord webhook with components V2 enabled
webhook_url="$DISCORD_WEBHOOK_URL?wait=true&with_components=true"

status_code=$(
  curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    --data "$payload"
)

if [ "$status_code" -lt 200 ] || [ "$status_code" -ge 300 ]; then
  echo "[Error] Failed to send Discord notification, HTTP status: $status_code" >&2
  exit 1
fi

exit 0
