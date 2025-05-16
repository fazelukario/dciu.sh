#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# TODO:
# - Add README.md with usage instructions, examples and configuration
# - Add LICENSE file and repository information
# - Add support for private repositories in Docker Hub
# - Add support for custom and private registries (e.g. GLCR, ACR, ECR, etc.)
# - Refactor code to use functions
# - Refactor and standardize logging and log messages across script and all notify modules (inspire from acme.sh)
# - Add support for recreating containers (created in portainer?) with Portainer webhooks and/or API
# - Add support for updating images after certain time passed after image release (e.g. 1 day, 1 week, etc.)
# - (Probably in very far future) Add support for Docker Swarm and Kubernetes (k8s) (currently only Docker Compose is supported)

# shellcheck disable=SC2034
VER=2.1.0

PROJECT_NAME="dciu.sh"

PROJECT="https://github.com/fazelukario/$PROJECT_NAME"

# Load configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/dciu.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi
# shellcheck source=dciu.conf
. "$CONFIG_FILE"

if [ -z "$LOG_FILE" ]; then LOG_FILE="$SCRIPT_DIR/dciu.sh.log"; fi

if [ -z "$DEBUG" ]; then DEBUG='0'; fi

if [ -z "$NOTIFY_SOURCE" ]; then NOTIFY_SOURCE="$(hostname -f)"; fi

_printargs() {
  _exitstatus="$?"
  if [ -z "$NO_TIMESTAMP" ] || [ "$NO_TIMESTAMP" = "0" ]; then
    printf -- "%s" "[$(date '+%Y-%m-%d %H:%M:%S')] "
  fi
  if [ -z "$2" ]; then
    printf -- "%s" "$1"
  else
    printf -- "%s" "$1='$2'"
  fi
  printf "\n"
  # return the saved exit status
  return "$_exitstatus"
}

_log() {
  [ -z "$LOG_FILE" ] && return
  _printargs "$@" >> "$LOG_FILE"
}

_info() {
  _log "$@"
  _printargs "$@"
}

_err() {
  _log "$@"
  _printargs "$@" >&2
  return 1
}

_debug() {
  if [ "${DEBUG:-0}" -ge 1 ]; then
    _log "$@"
    _printargs "$@"
  fi
}

# Logging helper
echo_log() {
  msg="$1"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

# helper: check if command exists
_exists() {
  cmd="$1"
  if [ -z "$cmd" ]; then return 1; fi

  if eval type type > /dev/null 2>&1; then
    eval type "$cmd" > /dev/null 2>&1
  elif command > /dev/null 2>&1; then
    command -v "$cmd" > /dev/null 2>&1
  else
    which "$cmd" > /dev/null 2>&1
  fi
  ret="$?"
  _debug "$cmd exists=$ret"
  return $ret
}

# function to escape JSON strings
_escape_json() { printf "%s" "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;s/\n/\\n/g;ta'; }

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
    _debug "No notify module configured, which means it's disabled, so will just return. Skipping notification for event: $event"
    return 0
  fi
  if [ -z "$NOTIFY_EVENT" ]; then
    _debug "No notify event configured, which means it's disabled, so will just return. Skipping notification for event: $event"
    return 0
  fi

  notify_events=$(printf "%s" "$NOTIFY_EVENT" | tr ',' ' ')

  # Skip notification if event not in notify_events and notify_events doesn't include "all"
  # If NOTIFY_EVENT includes "none", disable all notifications
  case " $notify_events " in
    *" none "*)
      _debug "Skipping notification for event: $event due to filter NOTIFY_EVENT=\"none\""
      return 0
      ;;
    *" all "*) ;; # notify all events
    *)
      case " $notify_events " in
        *" $event "*) ;; # allowed event
        *)
          _debug "Skipping notification for event: $event due to filter NOTIFY_EVENT=\"$NOTIFY_EVENT\""
          return 0
          ;;
      esac
      ;;
  esac

  _send_err=0
  for mod in $(echo "$NOTIFY_MODULE" | tr ',' " "); do
    mod_file="$SCRIPT_DIR/notify/${mod}.sh"
    _info "Sending notification for event $event via module: $mod"
    _debug "Found $mod_file for notify module $mod"

    if [ -z "$mod_file" ]; then
      _err "Cannot find notify module file for $mod"
      continue
    fi

    if ! (
      # Check if notify module file exists
      if ! [ -f "$mod_file" ]; then
        _err "Notify module $mod_file is not a file or not found"
        return 1
      fi

      # shellcheck disable=SC1090
      if ! . "$mod_file"; then
        _err "Error loading file $mod_file. Please check your API file and try again."
        return 1
      fi

      mod_command="${mod}_send"
      if ! _exists "$mod_command"; then
        _err "It seems that your API file is not correct. Make sure it has a function named: $mod_command"
        return 1
      fi

      if ! $mod_command "$event" "$container" "$image" "$old_digest" "$new_digest" "$mode" "$running" "$message"; then
        _err "Error sending notification for event $event using $mod_command"
        return 1
      fi

      return 0
    ); then
      _err "Error setting notify module $mod_file"
      _send_err=1
    else
      _info "Notification sent for event $event via module: $mod"
    fi
  done

  return $_send_err
}

# Parse image information
parse_image() {
  _img_to_parse="$1"

  # Parse image registry information
  # check if first part of image name contains a dot, then it's a registry domain and not from hub.docker.com
  if printf '%s' "$_img_to_parse" | awk -F':' '{print $1}' | awk -F'/' '{print $1}' | grep -q '\.'; then
    IMAGE_REGISTRY=$(echo "$_img_to_parse" | awk -F'/' '{print $1}')
    IMAGE_REGISTRY_API=$IMAGE_REGISTRY
    IMAGE_PATH_FULL=$(echo "$_img_to_parse" | cut -d '/' -f '2-') # consider posibility of moving to awk in the future
    IMAGE_NAMESPACE=$(echo "$IMAGE_PATH_FULL" | awk -F'/' '{print $1}')
  elif [ "$(echo "$_img_to_parse" | awk -F'/' '{print NF-1}')" = 0 ]; then
    IMAGE_REGISTRY="hub.docker.com"
    IMAGE_REGISTRY_API="hub.docker.com"
    IMAGE_PATH_FULL="library/$_img_to_parse"
    IMAGE_NAMESPACE="library"
  else
    IMAGE_REGISTRY="hub.docker.com"
    IMAGE_REGISTRY_API="hub.docker.com"
    IMAGE_PATH_FULL="$_img_to_parse"
    IMAGE_NAMESPACE=$(echo "$IMAGE_PATH_FULL" | awk -F'/' '{print $1}')
  fi

  # parse image information
  if printf '%s' "$IMAGE_PATH_FULL" | grep -q ':'; then
    IMAGE_PATH=$(echo "$IMAGE_PATH_FULL" | awk -F':' '{print $1}')
    IMAGE_REPOSITORY=$(echo "$IMAGE_PATH" | awk -F'/' '{print $2}')
    IMAGE_TAG=$(echo "$IMAGE_PATH_FULL" | awk -F':' '{print $2}')
    #IMAGE_LOCAL="$_img_to_parse" # currently not used
  else
    IMAGE_PATH="$IMAGE_PATH_FULL"
    IMAGE_REPOSITORY=$(echo "$IMAGE_PATH" | awk -F'/' '{print $2}')
    IMAGE_TAG="latest"
    #IMAGE_LOCAL="$_img_to_parse:latest" # currently not used
  fi

  # build registry URL for the image
  # shellcheck disable=SC2034
  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ]; then
    if [ "$IMAGE_NAMESPACE" = "library" ]; then
      IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/_/${IMAGE_REPOSITORY}"
    else
      IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/r/${IMAGE_PATH}"
    fi
  else
    IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/${IMAGE_PATH}"
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

  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ] && [ "$PRIVATE_REPO" != "true" ]; then
    # Get manifest digest from Docker Hub API
    api="https://${IMAGE_REGISTRY_API}/v2/namespaces/${IMAGE_NAMESPACE}/repositories/${IMAGE_REPOSITORY}/tags/${IMAGE_TAG}"
    resp=$(curl -s "$api")
    digest=$(echo "$resp" | jq -r '.digest' | awk -F':' '{print $2}') # consider posibility of replacing jq with pure grep, awk and etc. in the future
    printf "%s" "$digest"
  elif [ "$IMAGE_REGISTRY" = "ghcr.io" ]; then
    # Token URL for GHCR
    token_url="https://${IMAGE_REGISTRY_API}/token?scope=repository:${IMAGE_PATH}:pull"
    # Retrieve token: use basic auth if credentials provided
    if [ -n "$GITHUB_TOKEN" ] || [ "$PRIVATE_REPO" = "true" ]; then
      if [ -z "$GITHUB_TOKEN" ]; then
        echo_log "Error: GITHUB_TOKEN must be set for private repository access ($img)"
        printf "%s" ""
        return 1
      fi
      token=$(curl -s -u "username:$GITHUB_TOKEN" "$token_url" | awk -F'"' 'NR==1{print $4}')
    else
      token=$(curl -s "$token_url" | awk -F'"' 'NR==1{print $4}')
    fi
    # Get digest from response header
    header=$(curl -sI -H "Authorization: Bearer $token" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "https://${IMAGE_REGISTRY_API}/v2/${IMAGE_PATH}/manifests/${IMAGE_TAG}")
    digest=$(echo "$header" | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r' | tr -d '\n' | awk -F':' '{print $2}')
    printf "%s" "$digest"
  else
    # manifest inspect contacts registry to get manifest digest
    # supported only those images that use pure Manifest V2 format
    printf "%s" "$(docker manifest inspect "$img" 2> /dev/null)" | sha256sum | awk '{print substr($1, 1, 64)}'
  fi
}

# Check if update available: outputs old and new digests and returns 1 if update needed
check_update() {
  img="$1"

  old="$(get_local_digest "$img")"
  new="$(get_remote_digest "$img")"

  if [ -z "$old" ]; then
    echo_log "Error: local image not found: $img"
    return 0
  fi

  if [ -z "$new" ]; then
    echo_log "Error: remote image not found: $img"
    return 0
  fi

  # Check if digests are different
  if [ "$old" != "$new" ]; then
    echo "$old $new"
    return 1
  fi
  return 0
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

  # Determine update_compose flag (label overrides config)
  compose_lbl="$(docker inspect --format "{{index .Config.Labels \"$LABEL_UPDATE_COMPOSE\"}}" "$cid")"
  update_compose=${compose_lbl:-$UPDATE_COMPOSE}

  # Determine if container using image from private repository
  PRIVATE_REPO="$(docker inspect --format "{{index .Config.Labels \"$LABEL_PRIVATE_REPO\"}}" "$cid")"

  # Skip if none mode
  if [ "$mode" = "none" ]; then
    echo_log "Skipping container $name ($img) due to selected mode: $mode"
    return
  fi

  parse_image "$img"

  # Check for update
  if dig="$(check_update "$img")"; then
    echo_log "No update for $name ($img)"
    return
  fi

  old_digest="$(echo "$dig" | awk '{print $1}')"
  new_digest="$(echo "$dig" | awk '{print $2}')"

  running="$(docker inspect --format '{{.State.Running}}' "$cid")"

  msg="$mode: update available for $name ($img): $old_digest -> $new_digest"
  echo_log "$msg"
  (notify_event update_available "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")

  if ! [ "$mode" = "autoupdate" ]; then
    return
  fi

  # Check container running state
  if [ "$running" != "true" ] && [ "$update_stopped" != "true" ]; then
    # Stopped container
    msg="Skipping stopped container $name ($img): update_stopped=$update_stopped"
    echo_log "$msg"
    (notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi

  # Skip containers that are part of Swarm stack
  stack_ns="$(docker inspect --format '{{index .Config.Labels "com.docker.stack.namespace"}}' "$cid")"
  if [ -n "$stack_ns" ]; then
    msg="Skipping container $name ($img): part of Docker Swarm stack ($stack_ns) \
        [Docker Swarm currently not supported due to lack of resources for testing, if you want to help, feel free to open an issue or PR]"
    echo_log "$msg"
    (notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi

  # Handle containers part of Docker Compose project
  compose_project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid")"
  if [ -n "$compose_project" ]; then
    compose_service="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$cid")"
    compose_file="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid")"

    if [ "$update_compose" != "true" ]; then
      msg="Skipping container $name ($img) [Service \"$compose_service\"] in Docker Compose project $compose_project ($compose_file): \
          update_compose=$update_compose"
      echo_log "$msg"
      (notify_event update_skipped "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    # Check if compose file exists
    if [ -z "$compose_file" ]; then
      msg="Error: Docker Compose file not found for container $name ($img)"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
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
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    if ! $comp_cmd -f "$compose_file" pull "$compose_service"; then
      msg="Error pulling image $img for container $name ($compose_service) in Compose project $compose_project ($compose_file)"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    msg="Successfully updated image $img for container $name ($compose_service) in Compose project $compose_project ($compose_file)"
    echo_log "$msg"

    # Stop and remove container
    if ! $comp_cmd -f "$compose_file" stop "$compose_service"; then
      msg="Error stopping container $name ($compose_service) in Compose project $compose_project ($compose_file)"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi
    if ! $comp_cmd -f "$compose_file" rm -f "$compose_service"; then
      msg="Error removing container $name ($compose_service) in Compose project $compose_project ($compose_file)"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) stopped and removed successfully"
    echo_log "$msg"

    # Recreate container
    if ! $comp_cmd -f "$compose_file" create --force-recreate --build; then
      msg="Error recreating container $name ($compose_service) in Compose project $compose_project ($compose_file)"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) recreated successfully"
    echo_log "$msg"

    # Start container if it was running before or if start_stopped=true
    if [ "$start_stopped" = "true" ] || [ "$running" = "true" ]; then
      if ! $comp_cmd -f "$compose_file" start; then
        msg="Error starting container $name ($compose_service) in Compose project $compose_project ($compose_file)"
        echo_log "$msg"
        (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
        return
      fi

      msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) (re)started successfully"
      echo_log "$msg"
    else
      msg="Container $name ($compose_service) in Compose project $compose_project ($compose_file) not started due to start_stopped=$start_stopped"
      echo_log "$msg"
    fi

    (notify_event updated "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")

    # Prune dangling images if enabled
    if ! [ "$prune_dangling" = "true" ]; then
      return
    fi

    echo_log "Pruning dangling images"
    if docker image prune -f; then
      echo_log "Dangling images pruned successfully"
    else
      echo_log "Error pruning dangling images"
    fi

    return
  fi

  cmd_script="$SCRIPT_DIR/cmds/${name}.sh"
  if ! [ -x "$cmd_script" ]; then
    msg="Error: cmd script not found or not executable: $cmd_script"
    echo_log "$msg"
    (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi

  # Pull new image
  if ! docker pull "$img"; then
    msg="Error pulling image $img for container $name"
    echo_log "$msg"
    (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
  fi

  msg="Successfully pulled image $img for container $name"
  echo_log "$msg"

  # Stop and remove container
  if ! docker stop "$cid"; then
    msg="Error stopping container $name ($img)"
    echo_log "$msg"
    (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi
  if ! docker rm "$cid"; then
    msg="Error removing container $name ($img)"
    echo_log "$msg"
    (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi

  msg="Container $name ($img) stopped and removed successfully"
  echo_log "$msg"

  # Recreate container via user script
  if ! "$cmd_script" >> "$LOG_FILE"; then
    msg="Error: cmd script failed: $cmd_script"
    echo_log "$msg"
    (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
    return
  fi

  msg="Container $name recreated successfully"
  echo_log "$msg"

  # Start container if it was running before or if start_stopped=true
  if [ "$start_stopped" = "true" ] || [ "$running" = "true" ]; then
    if ! docker start "$name"; then
      msg="Error: failed to start container $name"
      echo_log "$msg"
      (notify_event update_failed "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")
      return
    fi

    msg="Container $name ($img) (re)started successfully"
    echo_log "$msg"
  else
    msg="Container $name ($img) not started due to start_stopped=$start_stopped"
    echo_log "$msg"
  fi

  (notify_event updated "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$msg")

  # Prune dangling images if enabled
  if ! [ "$prune_dangling" = "true" ]; then
    return
  fi

  echo_log "Pruning dangling images"
  if docker image prune -f; then
    echo_log "Dangling images pruned successfully"
  else
    echo_log "Error pruning dangling images"
  fi
}

# Iterate containers by label and mode
main() {
  # Get all containers
  cids="$(docker ps -q -a)"
  for cid in $cids; do
    (process_container "$cid")
  done
  echo_log "All containers processed."
}

main
