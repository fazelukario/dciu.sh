#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# TODO:
# - Rewrite notify function (and all notify scripts) to load (source) scripts (modules) (. "${module}.sh") \
#   and send notifications calling corresponding send function "${module}_send()" instead of executing them directly
# - Add README.md with usage instructions, examples and configuration
# - Add LICENSE file and repository information
# - Refactor code to use functions
# - Refactor and standardize logging and log messages across script and all notify modules
# - Add support for recreating containers (created in portainer?) with Portainer webhooks and/or API
# - (Probably in very far future) Add support for Docker Swarm and Kubernetes (k8s) (currently only Docker Compose is supported)

export DCIU_VER=1.6.3

export DCIU_PROJECT_NAME="dciu.sh"

export DCIU_PROJECT="https://github.com/fazelukario/$DCIU_PROJECT_NAME"

# Load configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/dciu.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck source=dciu.conf
. "$CONFIG_FILE"

if [ -z "$NOTIFY_SOURCE" ]; then
  DCIU_NOTIFY_SOURCE="$(hostname -f)"
  export DCIU_NOTIFY_SOURCE
else
  export DCIU_NOTIFY_SOURCE="$NOTIFY_SOURCE"
fi

if ! chmod "+x" "$SCRIPT_DIR/notify/"*.sh; then
  echo_log "[Error] Failed to make notify scripts executable."
fi

# Logging helper
echo_log() {
  msg="$1"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

# Notification helper: call notify modules if exists and event matches filter
notify_event() {
  event="$1" # e.g. update_available, updated, update_failed, update_skipped
  container="$2"
  image="$3"
  old_digest="$4"
  new_digest="$5"
  mode="$6"
  running="$7"
  message="$8"

  if [ -z "$NOTIFY_MODULE" ]; then
    echo_log "No notify module configured, skipping notification for event: $event"
    return
  fi
  if [ -z "$NOTIFY_EVENT" ]; then
    echo_log "No notify event configured, skipping notification for event: $event"
    return
  fi

  notify_events=$(printf "%s" "$NOTIFY_EVENT" | tr ',' ' ')

  # Skip notification if event not in notify_events and notify_events doesn't include "all"
  # If NOTIFY_EVENT includes "none", disable all notifications
  case " $notify_events " in
    *" none "*)
      echo_log "Skipping notification for event: $event due to filter NOTIFY_EVENT=\"none\""
      return
      ;;
    *" all "*) ;; # notify all events
    *)
      case " $notify_events " in
        *" $event "*) ;; # allowed event
        *)
          echo_log "Skipping notification for event: $event due to filter NOTIFY_EVENT=\"$NOTIFY_EVENT\""
          return
          ;;
      esac
      ;;
  esac

  for mod in $(echo "$NOTIFY_MODULE" | tr ',' " "); do
    mod_script="$SCRIPT_DIR/notify/${mod}.sh"
    if [ -x "$mod_script" ]; then
      if ! "$mod_script" "$event" "$container" "$image" "$old_digest" "$new_digest" "$mode" "$running" "$message"; then
        echo_log "[Error] notify module failed: $mod_script"
      else
        echo_log "Notification sent for event $event via module: $mod"
      fi
    elif [ -f "$mod_script" ]; then
      echo_log "[Error] notify module not executable: $mod_script"
    else
      echo_log "[Error] notify module not found: $mod_script"
    fi
  done
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

  # Determine prune_dangling flag (label overrides config)
  prune_lbl="$(docker inspect --format "{{index .Config.Labels \"$LABEL_PRUNE_DANGLING\"}}" "$cid")"
  prune_dangling=${prune_lbl:-$PRUNE_DANGLING}

  # Skip if none mode
  if [ "$mode" = "none" ]; then
    echo_log "Skipping container $name ($img) due to selected mode: $mode"
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
      # Check container running state
      running="$(docker inspect --format '{{.State.Running}}' "$cid")"
      if [ "$running" != "true" ] && [ "$update_stopped" != "true" ]; then
        # Stopped container
        msg="Skipping stopped container $name ($img): update_stopped=$update_stopped"
        echo_log "$msg"
        notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        return
      fi

      # Handle containers part of Docker Compose project
      compose_project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid")"
      if [ -n "$compose_project" ]; then
        compose_service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$cid")"
        compose_file="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid")"

        if [ "$UPDATE_CONTAINERS_IN_COMPOSE" != "true" ]; then
          msg="Skipping container $name ($img) [Service \"$compose_service\"] in Docker Compose project $compose_project ($compose_file): \
          UPDATE_CONTAINERS_IN_COMPOSE=$UPDATE_CONTAINERS_IN_COMPOSE"
          echo_log "$msg"
          notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        # Check if compose file exists
        if [ -z "$compose_file" ]; then
          msg="Error: Docker Compose file not found for container $name ($img)"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        msg="Updating Docker Compose service $compose_service in project $compose_project ($compose_file)"
        echo_log "$msg"

        if command -v docker compose > /dev/null 2>&1; then
          comp_cmd="docker compose"
        elif command -v docker-compose > /dev/null 2>&1; then
          comp_cmd="docker-compose"
        else
          msg="Error: docker compose and docker-compose not found"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        if ! $comp_cmd -f "$compose_file" pull "$compose_service"; then
          msg="Error pulling image $img for container $name ($compose_service) in Compose project $compose_project ($compose_file)"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        msg="Successfully updated image $img for container $name ($compose_service) in Compose project $compose_project ($compose_file)"
        echo_log "$msg"

        # Stop and remove container
        if ! $comp_cmd -f "$compose_file" stop "$compose_service"; then
          msg="Error stopping container $name ($compose_service) in Compose project $compose_project ($compose_file)"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi
        if ! $comp_cmd -f "$compose_file" rm -f "$compose_service"; then
          msg="Error removing container $name ($compose_service) in Compose project $compose_project ($compose_file)"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) stopped and removed successfully"
        echo_log "$msg"

        # Recreate container
        if ! $comp_cmd -f "$compose_file" create --force-recreate --build; then
          msg="Error recreating container $name ($compose_service) in Compose project $compose_project ($compose_file)"
          echo_log "$msg"
          notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
          return
        fi

        msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) recreated successfully"
        echo_log "$msg"

        # Start container if it was running before or if start_stopped=true
        if [ "$start_stopped" = "true" ] || [ "$running" = "true" ]; then
          if ! $comp_cmd -f "$compose_file" start; then
            msg="Error starting container $name ($compose_service) in Compose project $compose_project ($compose_file)"
            echo_log "$msg"
            notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
            return
          fi

          msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) (re)started successfully"
          echo_log "$msg"
        else
          msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) not started due to start_stopped=$start_stopped"
          echo_log "$msg"
        fi

        notify_event updated "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"

        # Prune dangling images if enabled
        if [ "$prune_dangling" = "true" ]; then
          echo_log "Pruning dangling images"
          if docker image prune -f; then
            echo_log "Dangling images pruned successfully"
          else
            echo_log "Error pruning dangling images"
          fi
        fi

        return
      fi

      # Skip containers that are part of Swarm stack
      stack_ns="$(docker inspect --format '{{index .Config.Labels "com.docker.stack.namespace"}}' "$cid")"
      if [ -n "$stack_ns" ]; then
        msg="Skipping container $name ($img): part of Docker Swarm stack ($stack_ns) \
        [Docker Swarm currently not supported due to lack of resources for testing, if you want to help, feel free to open an issue or PR]"
        echo_log "$msg"
        notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        return
      fi

      # Pull new image
      if ! docker pull "$img"; then
        msg="Error pulling image $img for container $name"
        echo_log "$msg"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
      fi

      msg="Successfully pulled image $img for container $name"
      echo_log "$msg"

      # Stop and remove container
      if ! docker stop "$cid"; then
        msg="Error stopping container $name ($img)"
        echo_log "$msg"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        return
      fi
      if ! docker rm "$cid"; then
        msg="Error removing container $name ($img)"
        echo_log "$msg"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        return
      fi

      msg="Container $name ($img) stopped and removed successfully"
      echo_log "$msg"

      # Recreate container via user script
      cmd_script="$SCRIPT_DIR/cmds/${name}.sh"
      if ! [ -x "$cmd_script" ]; then
        msg="Error: cmd script not found or not executable: $cmd_script"
        echo_log "$msg"
        notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"
        return
      fi

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
        msg="Container $name ($img) not started due to start_stopped=$start_stopped"
        echo_log "$msg"
      fi

      notify_event updated "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg"

      # Prune dangling images if enabled
      if [ "$prune_dangling" = "true" ]; then
        echo_log "Pruning dangling images"
        if docker image prune -f; then
          echo_log "Dangling images pruned successfully"
        else
          echo_log "Error pruning dangling images"
        fi
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
