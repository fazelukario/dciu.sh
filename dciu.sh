#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# TODO:
# - Add README.md with usage instructions, examples and configuration
# - Add LICENSE file and repository information
# - Add support for private repositories in Docker Hub
# - Add support for custom and private registries (e.g. GLCR, ACR, ECR, etc.)
# - Refactor code to use functions
# - Add support for recreating containers (created in portainer?) with Portainer webhooks and/or API
# - Add support for updating images after certain time passed after image release (e.g. 1 day, 1 week, etc.)
# - (Probably in very far future) Add support for Docker Swarm and Kubernetes (k8s) (currently only Docker Compose is supported)
# - (Probably in far future) Add syslog support (SYS_LOG with syslog levels, like acme.sh)
# - (Probably in future) Add colored output (like acme.sh's __red/__green)

VER=2.3.0

PROJECT_NAME="dciu.sh"

PROJECT="https://github.com/fazelukario/$PROJECT_NAME"

USER_AGENT="$PROJECT_NAME/$VER ($PROJECT)"

DEBUG_LEVEL_NONE=0
DEBUG_LEVEL_1=1
DEBUG_LEVEL_2=2
DEBUG_LEVEL_3=3

LOG_LEVEL_1=1
LOG_LEVEL_2=2
LOG_LEVEL_3=3

HIDDEN_VALUE="[hidden](set OUTPUT_INSECURE=1 to see this value)"

# check_update return codes
CHECK_UP_TO_DATE=0
CHECK_UPDATE_AVAILABLE=1
CHECK_FAILED=2

# Logging: _info -> stdout, _err and _debug* -> stderr; all of them also go to LOG_FILE
# (debug lines only up to LOG_LEVEL, which defaults to DEBUG).
# Except for _err (always returns 1), the helpers return the caller's $? untouched.

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
  __log_ret="$?"
  if [ -n "$LOG_FILE" ]; then
    _printargs "$@" >> "$LOG_FILE"
  fi
  return "$__log_ret"
}

_info() {
  __info_ret="$?"
  _log "$@"
  _printargs "$@"
  return "$__info_ret"
}

_err() {
  _log "$@"
  _printargs "$@" >&2
  return 1
}

# status debug_level log_level msg [value]
# The _debug* wrappers pass their caller's $? as status, so nested helpers never share a saved value.
__debugn() {
  __debugn_ret="$1"
  __debugn_debug_level="$2"
  __debugn_log_level="$3"
  shift 3
  if [ "${LOG_LEVEL:-${DEBUG:-$DEBUG_LEVEL_NONE}}" -ge "$__debugn_log_level" ]; then
    _log "$@"
  fi
  if [ "${DEBUG:-$DEBUG_LEVEL_NONE}" -ge "$__debugn_debug_level" ]; then
    _printargs "$@" >&2
  fi
  return "$__debugn_ret"
}

_debug() { __debugn "$?" "$DEBUG_LEVEL_1" "$LOG_LEVEL_1" "$@"; }
_debug2() { __debugn "$?" "$DEBUG_LEVEL_2" "$LOG_LEVEL_2" "$@"; }
_debug3() { __debugn "$?" "$DEBUG_LEVEL_3" "$LOG_LEVEL_3" "$@"; }

# status debug_level log_level name value: like __debugn, but the value is hidden unless OUTPUT_INSECURE=1
__secure_debugn() {
  if [ "$OUTPUT_INSECURE" = "1" ]; then
    __debugn "$@"
  else
    __debugn "$1" "$2" "$3" "$4" "$HIDDEN_VALUE"
  fi
}

_secure_debug() { __secure_debugn "$?" "$DEBUG_LEVEL_1" "$LOG_LEVEL_1" "$@"; }
_secure_debug2() { __secure_debugn "$?" "$DEBUG_LEVEL_2" "$LOG_LEVEL_2" "$@"; }
_secure_debug3() { __secure_debugn "$?" "$DEBUG_LEVEL_3" "$LOG_LEVEL_3" "$@"; }

# text secret: print text with every occurrence of secret replaced by [hidden] (as is with OUTPUT_INSECURE=1)
# e.g. for API error pages that echo the request URL, which carries a token
_hide_secret() {
  __hs_text="$1"
  __hs_secret="$2"
  if [ -z "$__hs_secret" ] || [ "$OUTPUT_INSECURE" = "1" ]; then
    printf "%s" "$__hs_text"
    return
  fi
  __hs_out=""
  # the quoted secret is matched literally, glob characters included
  while :; do
    case "$__hs_text" in
      *"$__hs_secret"*)
        __hs_out="$__hs_out${__hs_text%%"$__hs_secret"*}[hidden]"
        __hs_text="${__hs_text#*"$__hs_secret"}"
        ;;
      *) break ;;
    esac
  done
  printf "%s" "$__hs_out$__hs_text"
}

# DEBUG and LOG_LEVEL must be non-negative integers; anything else is reported and treated as 0
_init_log_levels() {
  case "$DEBUG" in
    '' | *[!0-9]*)
      [ -z "$DEBUG" ] || _err "Invalid DEBUG='$DEBUG' (must be a number 0-3), using 0"
      DEBUG="$DEBUG_LEVEL_NONE"
      ;;
  esac
  case "$LOG_LEVEL" in
    *[!0-9]*)
      _err "Invalid LOG_LEVEL='$LOG_LEVEL' (must be a number 0-3), using 0"
      LOG_LEVEL=0
      ;;
  esac
}

# Load configuration
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/dciu.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  _err "Config file not found: $CONFIG_FILE"
  exit 1
fi
# shellcheck source=dciu.conf
. "$CONFIG_FILE"

if [ -z "$LOG_FILE" ]; then LOG_FILE="$SCRIPT_DIR/dciu.sh.log"; fi

if [ -z "$DEBUG" ]; then DEBUG='0'; fi

if [ -z "$NOTIFY_SOURCE" ]; then NOTIFY_SOURCE="$(hostname -f)"; fi

# settings added after 2.3.0: existing configs don't have them
if [ -z "$COMPOSE_RECREATE" ]; then COMPOSE_RECREATE='service'; fi
if [ -z "$COMPOSE_BUILD" ]; then COMPOSE_BUILD='false'; fi
if [ -z "$LABEL_COMPOSE_RECREATE" ]; then LABEL_COMPOSE_RECREATE='dciu.compose-recreate'; fi
if [ -z "$LABEL_COMPOSE_BUILD" ]; then LABEL_COMPOSE_BUILD='dciu.compose-build'; fi
if [ -z "$SKIP_IDENTICAL_IMAGES" ]; then SKIP_IDENTICAL_IMAGES='1'; fi
if [ -z "$LABEL_SKIP_IDENTICAL_IMAGES" ]; then LABEL_SKIP_IDENTICAL_IMAGES='dciu.skip-identical-images'; fi

# helper: check if command exists
_exists() {
  cmd="$1"
  if [ -z "$cmd" ]; then return 1; fi

  if eval type type > /dev/null 2>&1; then
    # quoted for eval: the name must not be parsed as shell code
    eval 'type "$cmd"' > /dev/null 2>&1
  elif command > /dev/null 2>&1; then
    command -v "$cmd" > /dev/null 2>&1
  else
    which "$cmd" > /dev/null 2>&1
  fi
  ret="$?"
  _debug3 "$cmd exists=$ret"
  return $ret
}

# function to escape JSON strings
_escape_json() { printf "%s" "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;s/\n/\\n/g;ta'; }

# [multiline]: base64-encode stdin (acme.sh's signature); without multiline the output is a single line
# shellcheck disable=SC2120 # multiline is optional
_base64() {
  if [ -n "$1" ]; then
    _debug3 "base64 multiline"
    __base64_encode
  else
    _debug3 "base64 single line"
    __base64_encode | tr -d '\r\n'
  fi
}

__base64_encode() {
  if _exists base64; then
    base64
  elif _exists openssl; then
    openssl base64 -e
  else
    _err "Cannot encode base64: neither base64 nor openssl found"
    return 1
  fi
}

# print the path of a new temp file
_mktemp() {
  if ! mktemp 2> /dev/null; then
    _err "Cannot create temp file."
    return 1
  fi
}

# HTTP_HEADER: temp file that receives the response headers of _post and _get (one per run, created in main)
_inithttp() {
  if [ -z "$HTTP_HEADER" ] || ! touch "$HTTP_HEADER" 2> /dev/null; then
    HTTP_HEADER="$(_mktemp)" || return 1
    _debug2 "HTTP_HEADER" "$HTTP_HEADER"
  fi
}

# body url [needbase64] [POST|PUT|DELETE] [content_type]  (acme.sh's signature; extra headers from _H1.._H5)
# Prints the response body (also left in $response) and returns curl's exit code;
# the HTTP status of the response is read with _http_status. needbase64 is accepted but ignored.
_post() {
  body="$1"
  _post_url="$2"
  httpmethod="${4:-POST}"
  _postContentType="$5"

  _debug "$httpmethod"
  _secure_debug "_post_url" "$_post_url"
  _secure_debug2 "body" "$body"
  _debug2 "_postContentType" "$_postContentType"

  if [ -z "$HTTP_HEADER" ]; then
    _err "Cannot send $httpmethod request: no temp file for the response headers (HTTP_HEADER)"
    return 1
  fi

  # no -L: a moved endpoint must fail instead of curl re-sending the POST as GET
  set -- --silent --dump-header "$HTTP_HEADER" --user-agent "$USER_AGENT" -X "$httpmethod"
  if [ -n "$_postContentType" ]; then
    set -- "$@" -H "Content-Type: $_postContentType"
  fi
  # curl ignores the empty ones
  set -- "$@" -H "$_H1" -H "$_H2" -H "$_H3" -H "$_H4" -H "$_H5"
  if [ -n "$body" ]; then
    set -- "$@" --data "$body"
  fi

  response="$(curl "$@" "$_post_url")"
  _ret="$?"
  if [ "$_ret" != "0" ]; then
    _err "Please refer to https://curl.haxx.se/libcurl/c/libcurl-errors.html for error code: $_ret"
  fi
  _debug "_ret" "$_ret"
  printf "%s" "$response"
  return "$_ret"
}

# url [onlyheader] [timeout]  (acme.sh's signature; extra headers from _H1.._H5)
# Prints the response body, or the response headers for onlyheader (also left in $response), and returns curl's
# exit code. Redirects are followed; _http_status reads the status of the last response.
_get() {
  _get_url="$1"
  _get_onlyheader="$2"
  _get_timeout="$3"

  _debug "GET"
  _debug "_get_url" "$_get_url"
  _debug2 "_get_timeout" "$_get_timeout"

  if [ -z "$HTTP_HEADER" ]; then
    _err "Cannot send GET request: no temp file for the response headers (HTTP_HEADER)"
    return 1
  fi

  set -- --silent -L --dump-header "$HTTP_HEADER" --user-agent "$USER_AGENT"
  if [ -n "$_get_timeout" ]; then
    set -- "$@" --connect-timeout "$_get_timeout"
  fi
  if [ -n "$_get_onlyheader" ]; then
    set -- "$@" -I
  fi
  # curl ignores the empty ones
  set -- "$@" -H "$_H1" -H "$_H2" -H "$_H3" -H "$_H4" -H "$_H5"

  response="$(curl "$@" "$_get_url")"
  _ret="$?"
  if [ "$_ret" != "0" ]; then
    _err "Please refer to https://curl.haxx.se/libcurl/c/libcurl-errors.html for error code: $_ret"
  fi
  _debug "_ret" "$_ret"
  printf "%s" "$response"
  return "$_ret"
}

# HTTP status code of the last _post/_get response (the last status line, so 100 Continue, proxy CONNECT and
# followed redirects are skipped)
_http_status() {
  grep '^HTTP' "$HTTP_HEADER" 2> /dev/null | tail -n 1 | cut -d ' ' -f 2 | tr -d '\r\n'
}

# remove this run's temp files
_cleanup() {
  if [ -n "$HTTP_HEADER" ]; then rm -f "$HTTP_HEADER"; fi
}

# Notification helper: call notify modules if exists and event matches filter
notify_event() {
  event="$1" # e.g. update_available, updated, update_failed, update_skipped, check_failed
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

    if [ ! -f "$mod_file" ]; then
      _err "Cannot find notify module file for $mod: $mod_file"
      _send_err=1
      continue
    fi
    _debug "Found $mod_file for notify module $mod"

    if ! (
      # headers set for another request must not leak into this module's requests (as in acme.sh)
      export _H1="" _H2="" _H3="" _H4="" _H5=""

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

      # the module logs its own reason on failure
      $mod_command "$event" "$container" "$image" "$old_digest" "$new_digest" "$mode" "$running" "$message"
    ); then
      _err "Failed to send notification for event $event via module: $mod"
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

# Detect the image store once per run (IMAGE_STORE): on the containerd image store (Docker Desktop, fresh
# Docker 29 installs) an image ID is the digest of the pulled index/manifest; on the classic store
# (graph drivers) it is the digest of the image config. Unknown counts as classic.
_init_image_store() {
  IMAGE_STORE="classic"
  case "$(docker info --format '{{json .DriverStatus}}' 2> /dev/null)" in
    *io.containerd.snapshotter*) IMAGE_STORE="containerd" ;;
  esac
  _debug "IMAGE_STORE" "$IMAGE_STORE"
}

# image: append the hex digests of image to local_digests (space-separated, no duplicates): every RepoDigest
# (one per manifest it was pulled through, listed by name, not by age) and, on the containerd store, its ID.
# Returns 1 when the image can't be inspected.
_add_image_digests() {
  _aid_image="$1"
  _aid_refs="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$_aid_image" 2> /dev/null)" || return 1
  if [ "$IMAGE_STORE" = "containerd" ]; then
    case "$_aid_image" in sha256:*) _aid_refs="$_aid_refs $_aid_image" ;; esac
  fi
  for _aid_ref in $_aid_refs; do
    # repo@sha256:<hex> or sha256:<hex> -> <hex>
    _aid_digest="${_aid_ref##*@}"
    _aid_digest="${_aid_digest#*:}"
    case " $local_digests " in
      *" $_aid_digest "*) ;;
      *) local_digests="${local_digests:+$local_digests }$_aid_digest" ;;
    esac
  done
}

# Get the local digests of the container's image: image_id -> local_digests; returns 1 when the image can't be inspected
get_local_digests() {
  local_digests=""
  _add_image_digests "$1"
}

# image image: 0 when both images have the same layers and config, e.g. after a registry re-published a tag (new
# index digest) without changing the image for this platform
_same_image_content() {
  _sic_a="$(docker image inspect --format '{{json .RootFS.Layers}}{{json .Config}}' "$1" 2> /dev/null)" || return 1
  _sic_b="$(docker image inspect --format '{{json .RootFS.Layers}}{{json .Config}}' "$2" 2> /dev/null)" || return 1
  [ -n "$_sic_a" ] && [ "$_sic_a" = "$_sic_b" ]
}

# With skip_identical_images=1: 0 when the tag $img points to the container's image $image_id or to an identical one
# (checked right after a pull)
_pulled_image_identical() {
  [ "$skip_identical_images" = "1" ] || return 1
  _pii_id="$(docker image inspect --format '{{.Id}}' "$img" 2> /dev/null)" || return 1
  [ -n "$_pii_id" ] || return 1
  if [ "$_pii_id" = "$image_id" ]; then
    return 0
  fi
  _same_image_content "$image_id" "$_pii_id"
}

# Get the remote digest of img without pulling: sets remote_digest (hex) and returns 0, or sets check_error
# (the reason, one line) and returns 1. Headers set for these requests are cleared before and after.
get_remote_digest() {
  _grd_img="$1"
  remote_digest=""
  check_error=""

  _H1="" _H2="" _H3="" _H4="" _H5=""
  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ] && [ "$PRIVATE_REPO" != "true" ]; then
    _get_dockerhub_digest
  elif [ "$IMAGE_REGISTRY" = "ghcr.io" ]; then
    _get_ghcr_digest
  else
    _get_manifest_digest "$_grd_img"
  fi
  _grd_ret="$?"
  _H1="" _H2="" _H3="" _H4="" _H5=""
  return "$_grd_ret"
}

# Docker Hub tags API: the digest of the tag (its index, or its manifest for single-platform images)
_get_dockerhub_digest() {
  _gdd_body="$(_get "https://${IMAGE_REGISTRY_API}/v2/namespaces/${IMAGE_NAMESPACE}/repositories/${IMAGE_REPOSITORY}/tags/${IMAGE_TAG}")"
  _gdd_ret="$?"
  if [ "$_gdd_ret" != "0" ]; then
    check_error="cannot reach the Docker Hub API (curl error $_gdd_ret)"
    return 1
  fi
  _gdd_status="$(_http_status)"
  _debug "status_code" "$_gdd_status"
  _debug2 "response" "$_gdd_body"

  if [ "$_gdd_status" != "200" ]; then
    check_error="the Docker Hub API returned HTTP $_gdd_status"
    # an error response is JSON with a message, or e.g. an HTML page from a proxy (only logged)
    _gdd_message="$(printf '%s' "$_gdd_body" | jq -r '.message // empty' 2> /dev/null | head -n 1)"
    if [ -n "$_gdd_message" ]; then
      check_error="$check_error: $_gdd_message"
    fi
    if [ -n "$_gdd_body" ]; then
      _err "$_gdd_body"
    fi
    return 1
  fi

  # consider posibility of replacing jq with pure grep, awk and etc. in the future
  _gdd_digest="$(printf '%s' "$_gdd_body" | jq -r '.digest // empty' 2> /dev/null)"
  case "$_gdd_digest" in
    *:*) remote_digest="${_gdd_digest#*:}" ;;
  esac
  if [ -z "$remote_digest" ]; then
    check_error="no digest in the Docker Hub API response"
    return 1
  fi
}

# ghcr.io: a pull token (anonymous, or with GITHUB_TOKEN), then the Docker-Content-Digest of the tag's manifest,
# requested with every type docker itself accepts (multi-arch images are an index)
_get_ghcr_digest() {
  if [ -n "$GITHUB_TOKEN" ]; then
    _H1="Authorization: Basic $(printf '%s' "username:$GITHUB_TOKEN" | _base64)"
  elif [ "$PRIVATE_REPO" = "true" ]; then
    check_error="GITHUB_TOKEN must be set for private repository access"
    return 1
  fi

  # the response carries the token: never logged
  _ggd_body="$(_get "https://${IMAGE_REGISTRY_API}/token?scope=repository:${IMAGE_PATH}:pull")"
  _ggd_ret="$?"
  _H1=""
  if [ "$_ggd_ret" != "0" ]; then
    check_error="cannot reach ghcr.io (curl error $_ggd_ret)"
    return 1
  fi
  _ggd_status="$(_http_status)"
  _debug "status_code" "$_ggd_status"
  if [ "$_ggd_status" != "200" ]; then
    check_error="the ghcr.io token request returned HTTP $_ggd_status"
    if [ -n "$_ggd_body" ]; then
      _err "$_ggd_body"
    fi
    return 1
  fi
  _ggd_token="$(printf '%s' "$_ggd_body" | jq -r '.token // empty' 2> /dev/null)"
  if [ -z "$_ggd_token" ]; then
    check_error="no token in the ghcr.io token response"
    return 1
  fi

  _H1="Authorization: Bearer $_ggd_token"
  _H2="Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"
  _get "https://${IMAGE_REGISTRY_API}/v2/${IMAGE_PATH}/manifests/${IMAGE_TAG}" "onlyheader" > /dev/null
  _ggd_ret="$?"
  if [ "$_ggd_ret" != "0" ]; then
    check_error="cannot reach ghcr.io (curl error $_ggd_ret)"
    return 1
  fi
  _ggd_status="$(_http_status)"
  _debug "status_code" "$_ggd_status"
  if [ "$_ggd_status" != "200" ]; then
    check_error="ghcr.io returned HTTP $_ggd_status for the manifest"
    return 1
  fi

  _ggd_digest="$(grep -i '^docker-content-digest:' "$HTTP_HEADER" | tail -n 1 | tr -d '\r' | sed 's/^[^:]*:[[:space:]]*//')"
  case "$_ggd_digest" in
    *:*) remote_digest="${_ggd_digest#*:}" ;;
  esac
  if [ -z "$remote_digest" ]; then
    check_error="no Docker-Content-Digest in the ghcr.io manifest response"
    return 1
  fi
}

# other registries: the hash of `docker manifest inspect img` (it contacts the registry); matches the local digest
# only for images with a plain manifest v2
_get_manifest_digest() {
  if ! _gmd_manifest="$(docker manifest inspect "$1" 2> /dev/null)" || [ -z "$_gmd_manifest" ]; then
    check_error="docker manifest inspect failed"
    return 1
  fi
  remote_digest="$(printf "%s" "$_gmd_manifest" | sha256sum | awk '{print substr($1, 1, 64)}')"
}

# Check if an update is available for $img, run by the container's image $image_id: sets old_digest (the first
# local digest) and new_digest (prints nothing); the image is up to date when new_digest is any of its digests.
# Returns CHECK_UP_TO_DATE, CHECK_UPDATE_AVAILABLE or CHECK_FAILED (check_error says why)
check_update() {
  old_digest=""
  new_digest=""
  check_error=""

  if ! get_local_digests "$image_id"; then
    check_error="cannot inspect the container's image $image_id"
    return "$CHECK_FAILED"
  fi
  if [ "$skip_identical_images" = "1" ]; then
    # the tag may point to an image identical to the container's (pulled after a re-publish, the recreate skipped):
    # its digests are the container's too
    _cu_tag_id="$(docker image inspect --format '{{.Id}}' "$img" 2> /dev/null)"
    if [ -n "$_cu_tag_id" ] && [ "$_cu_tag_id" != "$image_id" ] && _same_image_content "$image_id" "$_cu_tag_id"; then
      _add_image_digests "$_cu_tag_id"
    fi
  fi
  _debug "local_digests" "$local_digests"
  if [ -z "$local_digests" ]; then
    check_error="the image has no registry digest (built or loaded locally?), set the label $LABEL_MODE=none to skip this container"
    return "$CHECK_FAILED"
  fi
  old_digest="${local_digests%% *}"

  if ! get_remote_digest "$img"; then
    return "$CHECK_FAILED"
  fi
  new_digest="$remote_digest"

  # digests are content addresses: a match from any repository name is the same image
  case " $local_digests " in
    *" $new_digest "*) return "$CHECK_UP_TO_DATE" ;;
  esac
  return "$CHECK_UPDATE_AVAILABLE"
}

# Read container cid with one docker inspect: sets name, img, image_id, running, the settings (container
# label, else global config) and the Swarm/Compose labels.
# Returns 1 when docker inspect fails, 2 when a value contains a line break (the output has one value per line).
_read_container() {
  _rc_cid="$1"

  # one value per line, in the order they are read below; the last line marks a complete, unshifted read
  _rc_format="{{.Name}}
{{.Config.Image}}
{{.Image}}
{{.State.Running}}
{{index .Config.Labels \"$LABEL_MODE\"}}
{{index .Config.Labels \"$LABEL_UPDATE_STOPPED\"}}
{{index .Config.Labels \"$LABEL_START_STOPPED\"}}
{{index .Config.Labels \"$LABEL_PRUNE_DANGLING\"}}
{{index .Config.Labels \"$LABEL_UPDATE_COMPOSE\"}}
{{index .Config.Labels \"$LABEL_PRIVATE_REPO\"}}
{{index .Config.Labels \"com.docker.stack.namespace\"}}
{{index .Config.Labels \"com.docker.compose.project\"}}
{{index .Config.Labels \"com.docker.compose.service\"}}
{{index .Config.Labels \"com.docker.compose.project.config_files\"}}
{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}
{{index .Config.Labels \"com.docker.compose.project.environment_file\"}}
{{index .Config.Labels \"$LABEL_COMPOSE_RECREATE\"}}
{{index .Config.Labels \"$LABEL_COMPOSE_BUILD\"}}
{{index .Config.Labels \"$LABEL_SKIP_IDENTICAL_IMAGES\"}}
dciu-inspect-end"
  _rc_out="$(docker container inspect --format "$_rc_format" "$_rc_cid" 2> /dev/null)" || return 1

  _rc_end=""
  {
    IFS= read -r _rc_name
    IFS= read -r img
    IFS= read -r image_id
    IFS= read -r running
    IFS= read -r _rc_mode
    IFS= read -r _rc_update_stopped
    IFS= read -r _rc_start_stopped
    IFS= read -r _rc_prune_dangling
    IFS= read -r _rc_update_compose
    IFS= read -r PRIVATE_REPO
    IFS= read -r stack_ns
    IFS= read -r compose_project
    IFS= read -r compose_service
    IFS= read -r compose_file
    IFS= read -r compose_working_dir
    IFS= read -r compose_env_files
    IFS= read -r _rc_compose_recreate
    IFS= read -r _rc_compose_build
    IFS= read -r _rc_skip_identical
    IFS= read -r _rc_end
    # a line break in a value shifts every later line: nothing may follow the end marker
    if IFS= read -r _rc_more; then _rc_end=""; fi
  } << EOF
$_rc_out
EOF
  if [ "$_rc_end" != "dciu-inspect-end" ]; then
    return 2
  fi

  name="${_rc_name#/}"
  # container label overrides global config
  mode="${_rc_mode:-$MODE}"
  update_stopped="${_rc_update_stopped:-$UPDATE_STOPPED}"
  start_stopped="${_rc_start_stopped:-$START_STOPPED}"
  prune_dangling="${_rc_prune_dangling:-$PRUNE_DANGLING}"
  update_compose="${_rc_update_compose:-$UPDATE_COMPOSE}"

  _debug "container" "$name ($_rc_cid)"
  _debug "image" "$img"
  _debug "mode" "$mode"
  _debug "update_stopped" "$update_stopped"
  _debug "start_stopped" "$start_stopped"
  _debug "prune_dangling" "$prune_dangling"
  _debug "update_compose" "$update_compose"
  _debug "private_repo" "$PRIVATE_REPO"

  skip_identical_images="${_rc_skip_identical:-$SKIP_IDENTICAL_IMAGES}"
  case "$skip_identical_images" in
    1 | true) skip_identical_images=1 ;;
    0 | false) skip_identical_images=0 ;;
    *)
      _err "Invalid SKIP_IDENTICAL_IMAGES='$skip_identical_images' for container $name, using '1'"
      skip_identical_images=1
      ;;
  esac
  _debug "skip_identical_images" "$skip_identical_images"

  if [ -n "$compose_project" ]; then
    compose_recreate="${_rc_compose_recreate:-$COMPOSE_RECREATE}"
    case "$compose_recreate" in
      service | stack) ;;
      *)
        _err "Invalid COMPOSE_RECREATE='$compose_recreate' for container $name, using 'service'"
        compose_recreate="service"
        ;;
    esac
    compose_build="${_rc_compose_build:-$COMPOSE_BUILD}"
    case "$compose_build" in
      true | false) ;;
      *)
        _err "Invalid COMPOSE_BUILD='$compose_build' for container $name, using 'false'"
        compose_build="false"
        ;;
    esac
    _debug "compose_recreate" "$compose_recreate"
    _debug "compose_build" "$compose_build"
  fi
}

# event msg: send the notification for the current container (notify_event logs its own failures)
_notify_container() {
  (notify_event "$1" "$name" "$img" "$old_digest" "$new_digest" "$mode" "$running" "$2")
}

# log and notify a failed update check (check_error says why); returns 1
_check_failed() {
  _cf_msg="Failed to check for updates of $name ($img): $check_error"
  _err "$_cf_msg"
  _notify_container check_failed "$_cf_msg"
  return 1
}

# msg: log and notify a failed update; returns 1
_update_failed() {
  _err "$1"
  _notify_container update_failed "$1"
  return 1
}

# msg: log and notify a skipped update; returns 0
_update_skipped() {
  _info "$1"
  _notify_container update_skipped "$1"
  return 0
}

# msg: notify the finished update and prune dangling images if enabled; returns 1 only when the prune failed
_finish_update() {
  _notify_container updated "$1"

  # Prune dangling images if enabled
  if [ "$prune_dangling" != "true" ]; then
    return 0
  fi

  _info "Pruning dangling images"
  if ! docker image prune -f; then
    _err "Error pruning dangling images"
    return 1
  fi
  _info "Dangling images pruned successfully"
}

# args...: run compose ($comp_cmd) for the container's own project: its name, working dir, config files and env files
# from the labels Compose set on the container (comma-separated lists, each entry one argument; a missing label drops
# its option), then args
_compose() {
  _co_n="$#"
  set -- "$@" -p "$compose_project"
  if [ -n "$compose_working_dir" ]; then
    set -- "$@" --project-directory "$compose_working_dir"
  fi
  _co_list="$compose_file,"
  while [ -n "$_co_list" ]; do
    _co_item="${_co_list%%,*}"
    _co_list="${_co_list#*,}"
    if [ -n "$_co_item" ]; then set -- "$@" -f "$_co_item"; fi
  done
  _co_list="$compose_env_files,"
  while [ -n "$_co_list" ]; do
    _co_item="${_co_list%%,*}"
    _co_list="${_co_list#*,}"
    if [ -n "$_co_item" ]; then set -- "$@" --env-file "$_co_item"; fi
  done
  # move the caller's args from the front to the end
  while [ "$_co_n" -gt 0 ]; do
    set -- "$@" "$1"
    shift
    _co_n=$((_co_n - 1))
  done
  $comp_cmd "$@"
}

# Update the container's Docker Compose service: pull its image, then recreate the service (COMPOSE_RECREATE=service,
# its depends_on services are left alone) or every service of the project (COMPOSE_RECREATE=stack) with 'up', started
# when the container was running or start_stopped=true. Returns 0 (also when skipped), or 1 when the update failed
_update_compose_service() {
  if [ "$update_compose" != "true" ]; then
    _update_skipped "Skipping container $name ($img) [Service \"$compose_service\"] in Docker Compose project $compose_project ($compose_file): update_compose=$update_compose"
    return 0
  fi

  # Check if compose file exists
  if [ -z "$compose_file" ]; then
    _update_failed "Docker Compose file not found for container $name ($img)"
    return 1
  fi

  _info "Updating Docker Compose service $compose_service in project $compose_project ($compose_file)"

  if docker compose version > /dev/null 2>&1; then
    comp_cmd="docker compose"
  elif _exists docker-compose; then
    comp_cmd="docker-compose"
  else
    _update_failed "Neither docker compose nor docker-compose found"
    return 1
  fi

  # the container as the messages below name it
  _ucs_ctr="$name ($compose_service) in Compose project $compose_project ($compose_file)"

  if ! _compose pull "$compose_service"; then
    _update_failed "Error pulling image $img for container $_ucs_ctr"
    return 1
  fi
  _info "Successfully updated image $img for container $_ucs_ctr"

  if _pulled_image_identical; then
    _update_skipped "Skipping container $name ($img): the pulled image is identical to the running one (the registry re-published the tag without changes)"
    return 0
  fi

  _ucs_start=""
  if [ "$running" = "true" ] || [ "$start_stopped" = "true" ]; then
    _ucs_start=1
    set -- up -d
  else
    set -- up --no-start
  fi
  if [ "$compose_recreate" = "stack" ]; then
    _ucs_what="All services of Compose project $compose_project ($compose_file)"
    set -- "$@" --force-recreate
  else
    _ucs_what="Container $_ucs_ctr"
    set -- "$@" --no-deps --force-recreate
  fi
  if [ "$compose_build" = "true" ]; then
    set -- "$@" --build
  fi
  if [ "$compose_recreate" != "stack" ]; then
    set -- "$@" "$compose_service"
  fi

  if ! _compose "$@"; then
    _update_failed "Error recreating container $_ucs_ctr"
    return 1
  fi
  if [ -n "$_ucs_start" ]; then
    msg="$_ucs_what recreated and (re)started successfully"
  else
    msg="$_ucs_what recreated, not started due to start_stopped=$start_stopped"
  fi
  _info "$msg"

  _finish_update "$msg"
}

# Update the container with its cmd script ($SCRIPT_DIR/cmds/<name>.sh); returns 0, or 1 when the update failed
_update_cmd_script() {
  cmd_script="$SCRIPT_DIR/cmds/${name}.sh"
  if ! [ -x "$cmd_script" ]; then
    _update_failed "Cmd script not found or not executable: $cmd_script"
    return 1
  fi

  # Pull new image
  if ! docker pull "$img"; then
    _update_failed "Error pulling image $img for container $name"
    return 1
  fi
  _info "Successfully pulled image $img for container $name"

  if _pulled_image_identical; then
    _update_skipped "Skipping container $name ($img): the pulled image is identical to the running one (the registry re-published the tag without changes)"
    return 0
  fi

  # Stop and remove container
  if ! docker stop "$cid"; then
    _update_failed "Error stopping container $name ($img)"
    return 1
  fi
  if ! docker rm "$cid"; then
    _update_failed "Error removing container $name ($img)"
    return 1
  fi
  _info "Container $name ($img) stopped and removed successfully"

  # Recreate container via user script
  if ! "$cmd_script" >> "${LOG_FILE:-/dev/null}"; then
    _update_failed "Cmd script failed: $cmd_script"
    return 1
  fi
  _info "Container $name recreated successfully"

  # Start container if it was running before or if start_stopped=true
  if [ "$start_stopped" = "true" ] || [ "$running" = "true" ]; then
    if ! docker start "$name"; then
      _update_failed "Failed to start container $name"
      return 1
    fi
    msg="Container $name ($img) (re)started successfully"
  else
    msg="Container $name ($img) not started due to start_stopped=$start_stopped"
  fi
  _info "$msg"

  _finish_update "$msg"
}

# cid: 0 when the container exists (also when docker ps itself fails), 1 when it is gone
_container_exists() {
  _ce_ids="$(docker ps -aq --filter "id=$1" 2> /dev/null)" || return 0
  [ -n "$_ce_ids" ]
}

# Check container cid for an update and handle it as its mode says.
# Returns 0, or 1 when the container can't be read or its update failed.
process_container() {
  cid="$1"

  _read_container "$cid"
  case "$?" in
    0) ;;
    2)
      _err "Cannot read the settings of container $cid: a label value contains a line break"
      return 1
      ;;
    *)
      # removed since docker ps listed it (e.g. by a compose recreate earlier in this run, or a --rm container)
      if ! _container_exists "$cid"; then
        _info "Container $cid no longer exists, skipping"
        return 0
      fi
      _err "Cannot inspect container $cid"
      return 1
      ;;
  esac

  # Skip if none mode
  if [ "$mode" = "none" ]; then
    _info "Skipping container $name ($img) due to selected mode: $mode"
    return 0
  fi

  # Skip pinned images: there is no newer image for a digest or an image ID
  case "$img" in
    *@*)
      _info "Skipping container $name ($img): the image is pinned to a digest"
      return 0
      ;;
    sha256:*)
      _info "Skipping container $name ($img): the container was created from an image ID"
      return 0
      ;;
    '' | *[!0-9a-f]*) ;;
    *)
      # all hex: a (short) image ID when it starts the container's image ID, else a repository name
      case "${image_id#sha256:}" in
        "$img"*)
          _info "Skipping container $name ($img): the container was created from an image ID"
          return 0
          ;;
      esac
      ;;
  esac

  parse_image "$img"

  # Check for update
  check_update
  _pc_check="$?"
  if [ "$_pc_check" = "$CHECK_FAILED" ]; then
    _check_failed
    return 1
  fi
  if [ "$_pc_check" != "$CHECK_UPDATE_AVAILABLE" ]; then
    _info "No update for $name ($img)"
    return 0
  fi

  _debug "old_digest" "$old_digest"
  _debug "new_digest" "$new_digest"

  msg="$mode: update available for $name ($img): $old_digest -> $new_digest"
  _info "$msg"
  _notify_container update_available "$msg"

  if [ "$mode" != "autoupdate" ]; then
    return 0
  fi

  # Check container running state
  if [ "$running" != "true" ] && [ "$update_stopped" != "true" ]; then
    _update_skipped "Skipping stopped container $name ($img): update_stopped=$update_stopped"
    return 0
  fi

  # Skip containers that are part of Swarm stack
  if [ -n "$stack_ns" ]; then
    msg="Skipping container $name ($img): part of Docker Swarm stack ($stack_ns)"
    msg="$msg [Docker Swarm currently not supported due to lack of resources for testing, if you want to help, feel free to open an issue or PR]"
    _update_skipped "$msg"
    return 0
  fi

  # Handle containers part of Docker Compose project
  if [ -n "$compose_project" ]; then
    _update_compose_service
  else
    _update_cmd_script
  fi
}

# Iterate containers by label and mode
main() {
  _init_log_levels

  # An unwritable LOG_FILE is reported once and the run logs to the console only: otherwise every log line
  # prints a shell error, and a cmd script (its output goes to LOG_FILE) would not run at all, leaving its
  # already removed container not recreated. printf, not ':', so a failed redirect can't exit the shell.
  if [ -n "$LOG_FILE" ] && ! { printf '' >> "$LOG_FILE"; } 2> /dev/null; then
    _unwritable_log_file="$LOG_FILE"
    LOG_FILE=""
    _err "Cannot write to LOG_FILE='$_unwritable_log_file', logging to the console only"
  fi

  # One temp file per run for the response headers of _post, never one inherited from the environment
  # (the EXIT trap deletes it). Without it notifications fail, but containers are still processed.
  HTTP_HEADER=""
  _inithttp
  trap '_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Get all containers
  if ! cids="$(docker ps -q -a)"; then
    _err "Cannot list containers"
    return 1
  fi
  _init_image_store

  # like acme.sh's cron: 1 when any container's check or update failed (skips and failed notifications don't count)
  _main_ret=0
  for cid in $cids; do
    if ! (process_container "$cid"); then
      _main_ret=1
    fi
  done
  _info "All containers processed."
  return "$_main_ret"
}

main
