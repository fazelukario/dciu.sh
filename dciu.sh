#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# Load configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/dciu.conf"
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
  event="$1" # e.g. update_available, updated, update_failed, update_skipped
  container="$2"
  image="$3"
  old_digest="$4"
  new_digest="$5"
  mode="$6"
  running="$7"
  message="$8"

  mod_script="$SCRIPT_DIR/notify/${NOTIFY_MODULE}.sh"

  if [ -x "$mod_script" ]; then
    if ! "$mod_script" "$event" "$container" "$image" "$old_digest" "$new_digest" "$mode" "$running" "$message"; then
      echo_log "Error: notify module failed: $mod_script"
    else
      echo_log "Notification sent for event: $event"
    fi
  elif [ -f "$mod_script" ]; then
    echo_log "Error: notify module not executable: $mod_script"
  else
    echo_log "Error: notify module not found: $mod_script"
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

  if [ -z "$old" ]; then
    echo_log "Error: local image not found: $img"
    return 1
  fi

  if [ -z "$new" ]; then
    echo_log "Error: remote image not found: $img"
    return 1
  fi

  # Check if digests are different
  if [ "$old" != "$new" ]; then
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
  mode=${mode_label:-$MODE}

  # Determine update_stopped flag
  upd_lbl="$(docker inspect --format "{{index .Config.Labels \"$LABEL_UPDATE_STOPPED\"}}" "$cid")"
  update_stopped=${upd_lbl:-$UPDATE_STOPPED}
  # Determine start_stopped flag
  st_lbl="$(docker inspect --format "{{index .Config.Labels \"$LABEL_START_STOPPED\"}}" "$cid")"
  start_stopped=${st_lbl:-$START_STOPPED}

  # Skip if none mode
  if [ "$mode" = "none" ]; then
    echo_log "Skipping container $name ($img) due to selected mode: $mode"
    return
  fi

  # Check container running state
  running="$(docker inspect --format '{{.State.Running}}' "$cid")"
  if [ "$running" != "true" ] && [ "$update_stopped" != "true" ]; then
    # Stopped container
    msg="Skipping stopped container $name ($img): update_stopped=false"
    echo_log "$msg"
    notify_event update_skipped "$name" "$img" "" "" "$mode" "$running" "$msg"
    return
  fi

  # Check for update
  if dig="$(check_update "$img")"; then
    old_digest="$(echo "$dig" | awk '{print $1}')"
    new_digest="$(echo "$dig" | awk '{print $2}')"

    msg="$mode: update available for $name ($img): $old_digest -> $new_digest"
    echo_log "$msg"
    notify_event update_available "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"

    if [ "$mode" = "autoupdate" ]; then
      # Pull new image
      if docker pull "$img"; then
        docker stop "$cid"
        docker rm "$cid"
        # Recreate container via user script
        cmd_script="$SCRIPT_DIR/cmds/${name}.sh"
        if [ -x "$cmd_script" ]; then
          if ! "$cmd_script"; then
            msg="Error: cmd script failed: $cmd_script"
            echo_log "$msg"
            notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
            return
          fi

          msg="Container $name recreated successfully"
          echo_log "$msg"

          # Start container if it was running before or if start_stopped=true
          if [ "$start_stopped" = "true" ] || [ "$running" = "true" ]; then
            if ! docker start "$name"; then
              msg="Error: failed to start container $name"
              echo_log "$msg"
              notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
              return
            fi
            msg="Container $name ($img) (re)started successfully"
            echo_log "$msg"
          else
            msg="Container $name ($img) not started due to start_stopped=false"
            echo_log "$msg"
          fi
          notify_event updated "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        else
          msg="Error: cmd script not found or not executable: $cmd_script"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        fi
      else
        msg="Error pulling image $img for container $name"
        echo_log "$msg"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
      fi
    fi
  else
    echo_log "No update for $name ($img)"
  fi
}

# Iterate containers by label and mode
main() {
  # Get all containers
  cids="$(docker ps -q -a)"
  for cid in $cids; do
    process_container "$cid"
  done
  echo_log "All containers processed."
}

main
