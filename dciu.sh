#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# Load configuration
CONFIG_FILE="$(dirname "$(realpath "$0")")/dciu.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck source=dciu.conf
. "$CONFIG_FILE"

# Logging helper
echo_log() {
  msg="$1"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

# Notification helper: call notify module if exists
notify_event() {
  event="$1" # e.g. update_available, updated, update_failed
  container="$2"
  image="$3"
  old_digest="$4"
  new_digest="$5"
  mode="$6"
  mod_script="$(dirname "$0")/notify/${NOTIFY_MODULE}.sh"
  if [ -x "$mod_script" ]; then
    "$mod_script" "$event" "$container" "$image" "$old_digest" "$new_digest" "$mode"
  else
    echo_log "Warning: notify module not found or not executable: $mod_script"
  fi
}

# Get local image digest (first RepoDigest)
get_local_digest() {
  img="$1"
  docker inspect --format '{{index .RepoDigests 0}}' "$img" 2> /dev/null | awk -F'@' '{print $2}' | awk -F':' '{print $2}'
}

# Get remote image digest without pulling
get_remote_digest() {
  img="$1"
  # manifest inspect contacts registry to get manifest digest
  printf "%s" "$(docker manifest inspect "$img" 2> /dev/null)" | sha256sum | awk '{print substr($1, 1, 64)}'
}

# Check if update available: outputs old and new digests and returns 0 if update needed
check_update() {
  img="$1"
  old="$(get_local_digest "$img")"
  new="$(get_remote_digest "$img")"
  if [ -z "$old" ] || [ -z "$new" ] || [ "$old" != "$new" ]; then
    echo "$old $new"
    return 0
  fi
  return 1
}

# Check for update and handle based on mode label
process_container() {
  cid="$1"
  img="$(docker inspect --format '{{.Config.Image}}' "$cid")"
  name="$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')"

  # Determine mode: container label overrides default
  mode_label="$(docker inspect --format "{{index .Config.Labels \"$LABEL_MODE\"}}" "$cid")"
  if [ -z "$mode_label" ]; then
    mode="$MODE"
  else
    mode="$mode_label"
  fi

  # Skip if none
  if [ "$mode" = "none" ]; then
    echo_log "Skipping $name ($img) due to mode none"
    return
  fi

  # Check for update
  if dig="$(check_update "$img")"; then
    old_digest="$(echo "$dig" | awk '{print $1}')"
    new_digest="$(echo "$dig" | awk '{print $2}')"

    echo_log "$mode: update available for $name ($img): $old_digest -> $new_digest"
    notify_event update_available "$name" "$img" "$old_digest" "$new_digest" "$mode"

    if [ "$mode" = "autoupdate" ]; then
      # Pull new image
      if docker pull "$img"; then
        docker stop "$cid"
        docker rm "$cid"
        # Rerun container via user script
        cmd_script="$(dirname "$0")/cmds/${name}.sh"
        if [ -x "$cmd_script" ]; then
          "$cmd_script"
          echo_log "Container $name restarted"
          notify_event updated "$name" "$img" "$old_digest" "$new_digest"
        else
          echo_log "Error: cmd script not found or not executable: $cmd_script"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest"
        fi
      else
        echo_log "Error pulling image $img"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest"
      fi
    fi
  else
    echo_log "No update for $name ($img)"
  fi
}

# Iterate containers by label and mode
main() {
  # Get all running containers
  cids="$(docker ps -q)"
  for cid in $cids; do
    process_container "$cid"
  done
  echo_log "All containers processed."
}

main
