#!/usr/bin/env sh

# dciu.sh - Docker Container Image Updater (dciu)

# TODO:
# - Add README.md with usage instructions, examples and configuration
# - Add LICENSE file and repository information
# - Add support for private repositories in Docker Hub
# - Add support for custom and private registries (e.g. GLCR, ACR, ECR, etc.)
# - Add support for recreating containers (created in portainer?) with Portainer webhooks and/or API
# - Add support for updating images after certain time passed after image release (e.g. 1 day, 1 week, etc.)
# - (Probably in very far future) Add support for Docker Swarm and Kubernetes (k8s) (currently only Docker Compose is supported)
# - (Probably in far future) Add syslog support (SYS_LOG with syslog levels, like acme.sh)
# - (Probably in future) Add colored output (like acme.sh's __red/__green)

VER=2.5.0

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
CHECK_LOCAL_IMAGE=3

# Defaults of the settings (a config may lack a setting or hold an invalid value), each the cautious choice
# shellcheck disable=SC2034 # read through eval by _init_settings and _container_setting
DEFAULT_MODE=monitor \
  DEFAULT_UPDATE_STOPPED=false \
  DEFAULT_START_STOPPED=false \
  DEFAULT_PRUNE_DANGLING=false \
  DEFAULT_UPDATE_COMPOSE=false \
  DEFAULT_PRIVATE_REPO=false \
  DEFAULT_COMPOSE_RECREATE=service \
  DEFAULT_COMPOSE_BUILD=false \
  DEFAULT_SKIP_IDENTICAL_IMAGES=true \
  DEFAULT_SKIP_LOCAL_IMAGES=true \
  DEFAULT_HTTP_TIMEOUT=30 \
  DEFAULT_OUTPUT_INSECURE=false \
  DEFAULT_NO_TIMESTAMP=false \
  DEFAULT_LOCK_FILE=/tmp/dciu.sh.lock

# The global settings _init_settings checks: name and type of value (see _setting_value)
_SETTINGS="MODE mode
UPDATE_STOPPED bool
START_STOPPED bool
PRUNE_DANGLING bool
UPDATE_COMPOSE bool
PRIVATE_REPO bool
COMPOSE_RECREATE recreate
COMPOSE_BUILD bool
SKIP_IDENTICAL_IMAGES bool
SKIP_LOCAL_IMAGES bool
HTTP_TIMEOUT seconds
OUTPUT_INSECURE bool
NO_TIMESTAMP bool"

# Logging: _info -> stdout, _err and _debug* -> stderr; all of them also go to LOG_FILE
# (debug lines only up to LOG_LEVEL, which defaults to DEBUG).
# Except for _err (always returns 1), the helpers return the caller's $? untouched.

# value: 0 when it spells true (1, yes or true in any case, surrounding spaces ignored). Uses only its own variable:
# it runs in every log line, also between a caller's _setting_value and its use of _sv
_is_true() {
  __it="$1"
  __it="${__it#"${__it%%[![:space:]]*}"}"
  __it="${__it%"${__it##*[![:space:]]}"}"
  case "$__it" in
    1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) return 0 ;;
  esac
  return 1
}

_printargs() {
  _exitstatus="$?"
  if ! _is_true "$NO_TIMESTAMP"; then
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

# status debug_level log_level name value: like __debugn, but the value is hidden unless OUTPUT_INSECURE is true
__secure_debugn() {
  if _is_true "$OUTPUT_INSECURE"; then
    __debugn "$@"
  else
    __debugn "$1" "$2" "$3" "$4" "$HIDDEN_VALUE"
  fi
}

_secure_debug() { __secure_debugn "$?" "$DEBUG_LEVEL_1" "$LOG_LEVEL_1" "$@"; }
_secure_debug2() { __secure_debugn "$?" "$DEBUG_LEVEL_2" "$LOG_LEVEL_2" "$@"; }
_secure_debug3() { __secure_debugn "$?" "$DEBUG_LEVEL_3" "$LOG_LEVEL_3" "$@"; }

# text secret: print text with every occurrence of secret replaced by [hidden] (as is when OUTPUT_INSECURE is true)
# e.g. for API error pages that echo the request URL, which carries a token
_hide_secret() {
  __hs_text="$1"
  __hs_secret="$2"
  if [ -z "$__hs_secret" ] || _is_true "$OUTPUT_INSECURE"; then
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

# digits -> 0-3 without arithmetic (a 20-digit value is no valid number for test): leading zeros are ignored,
# anything above 3 is 3
__log_level_clamp() {
  __llc_value="$1"
  while :; do
    case "$__llc_value" in
      0?*) __llc_value="${__llc_value#0}" ;;
      *) break ;;
    esac
  done
  case "$__llc_value" in
    '') __llc_value=0 ;;
    [4-9] | ??*) __llc_value=3 ;;
  esac
  printf '%s' "$__llc_value"
}

# DEBUG and LOG_LEVEL must be non-negative integers; anything else is reported and treated as 0
_init_log_levels() {
  case "$DEBUG" in
    '' | *[!0-9]*)
      [ -z "$DEBUG" ] || _err "Invalid DEBUG='$DEBUG' (must be a number 0-3), using 0"
      DEBUG="$DEBUG_LEVEL_NONE"
      ;;
  esac
  DEBUG="$(__log_level_clamp "$DEBUG")"
  case "$LOG_LEVEL" in
    *[!0-9]*)
      _err "Invalid LOG_LEVEL='$LOG_LEVEL' (must be a number 0-3), using 0"
      LOG_LEVEL=0
      ;;
  esac
  # empty LOG_LEVEL: follows DEBUG
  if [ -n "$LOG_LEVEL" ]; then
    LOG_LEVEL="$(__log_level_clamp "$LOG_LEVEL")"
  fi
}

# type value: check the value of a setting, any case, surrounding spaces and line breaks ignored (no forks).
# 0: valid, the canonical value in _sv; 1: invalid, _sv is the trimmed value and _sv_must lists the accepted ones;
# 2: empty. Types: bool (1 yes true -> true, 0 no false -> false), mode (autoupdate monitor none), recreate
# (service stack), seconds (0-86400, leading zeros dropped)
_setting_value() {
  _sv="$2"
  _sv="${_sv#"${_sv%%[![:space:]]*}"}"
  _sv="${_sv%"${_sv##*[![:space:]]}"}"
  if [ -z "$_sv" ]; then
    return 2
  fi
  case "$1" in
    bool)
      _sv_must="true, false, yes, no, 1 or 0"
      case "$_sv" in
        1 | [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee]) _sv=true ;;
        0 | [Nn][Oo] | [Ff][Aa][Ll][Ss][Ee]) _sv=false ;;
        *) return 1 ;;
      esac
      ;;
    mode)
      _sv_must="autoupdate, monitor or none"
      case "$_sv" in
        [Aa][Uu][Tt][Oo][Uu][Pp][Dd][Aa][Tt][Ee]) _sv=autoupdate ;;
        [Mm][Oo][Nn][Ii][Tt][Oo][Rr]) _sv=monitor ;;
        [Nn][Oo][Nn][Ee]) _sv=none ;;
        *) return 1 ;;
      esac
      ;;
    recreate)
      _sv_must="service or stack"
      case "$_sv" in
        [Ss][Ee][Rr][Vv][Ii][Cc][Ee]) _sv=service ;;
        [Ss][Tt][Aa][Cc][Kk]) _sv=stack ;;
        *) return 1 ;;
      esac
      ;;
    seconds)
      _sv_must="a number of seconds 0-86400"
      case "$_sv" in
        *[!0-9]*) return 1 ;;
      esac
      while :; do
        case "$_sv" in
          0?*) _sv="${_sv#0}" ;;
          *) break ;;
        esac
      done
      # no arithmetic on a number that may not fit
      case "$_sv" in
        ??????*) return 1 ;;
      esac
      [ "$_sv" -le 86400 ] || return 1
      ;;
    *)
      _sv_must="(unknown type $1)"
      return 1
      ;;
  esac
}

# Check the global settings once per run (_SETTINGS and NOTIFY_EVENT): an empty one gets its default silently, an
# invalid one is reported and gets its default; _settings_invalid=1 then (the run ends with exit code 1)
_init_settings() {
  _settings_invalid=0
  while read -r _is_name _is_type; do
    _is_raw="" _is_default=""
    eval "_is_raw=\${$_is_name}"
    eval "_is_default=\$DEFAULT_$_is_name"
    _setting_value "$_is_type" "$_is_raw"
    case "$?" in
      0) eval "$_is_name=\$_sv" ;;
      2) eval "$_is_name=\$_is_default" ;;
      *)
        _err "Invalid $_is_name='$_is_raw' (must be $_sv_must), using '$_is_default'"
        eval "$_is_name=\$_is_default"
        _settings_invalid=1
        ;;
    esac
  done << EOF
$_SETTINGS
EOF

  # empty: no notifications
  if [ -z "$NOTIFY_EVENT" ]; then
    return 0
  fi
  _is_rest="$(printf '%s' "$NOTIFY_EVENT" | tr 'A-Z,\t\n' 'a-z   ') "
  _is_events=""
  while [ -n "$_is_rest" ]; do
    _is_event="${_is_rest%% *}"
    _is_rest="${_is_rest#* }"
    case "$_is_event" in
      '') ;;
      update_available | updated | update_failed | update_skipped | check_failed | all | none)
        _is_events="${_is_events:+$_is_events }$_is_event"
        ;;
      *)
        _err "Invalid NOTIFY_EVENT name '$_is_event' (must be update_available, updated, update_failed, update_skipped, check_failed, all or none), ignored"
        _settings_invalid=1
        ;;
    esac
  done
  NOTIFY_EVENT="$_is_events"
}

# type NAME label_name label_value: a container's setting in _sv — the label's value, else the global NAME, else
# DEFAULT_NAME (an invalid global was reported by _init_settings). Returns 1 when the label value is invalid:
# _cs_value is the trimmed value, _cs_error says what is wrong
_container_setting() {
  _cs_value=""
  _cs_error=""
  _setting_value "$1" "$4"
  case "$?" in
    0) return 0 ;;
    1)
      _cs_value="$_sv"
      _cs_error="$3='$_sv' (must be $_sv_must)"
      _sv=""
      return 1
      ;;
  esac
  _cs_global=""
  eval "_cs_global=\${$2}"
  if _setting_value "$1" "$_cs_global"; then
    return 0
  fi
  eval "_sv=\$DEFAULT_$2"
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

# labels added after 2.3.0: existing configs don't have them (the settings' defaults are in _init_settings)
if [ -z "$LABEL_COMPOSE_RECREATE" ]; then LABEL_COMPOSE_RECREATE='dciu.compose-recreate'; fi
if [ -z "$LABEL_COMPOSE_BUILD" ]; then LABEL_COMPOSE_BUILD='dciu.compose-build'; fi
if [ -z "$LABEL_SKIP_IDENTICAL_IMAGES" ]; then LABEL_SKIP_IDENTICAL_IMAGES='dciu.skip-identical-images'; fi
if [ -z "$LABEL_SKIP_LOCAL_IMAGES" ]; then LABEL_SKIP_LOCAL_IMAGES='dciu.skip-local-images'; fi
if [ -z "$LABEL_HTTP_TIMEOUT" ]; then LABEL_HTTP_TIMEOUT='dciu.http-timeout'; fi

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

# a tab and a carriage return for sed scripts (POSIX sed has no \t or \r)
_TAB="$(printf '\t')" _CR="$(printf '\r')"

# text: print text escaped for a JSON string (also valid in Python string literals): backslash, quote, tab, CR and
# line breaks escaped, the other control characters (not allowed raw in JSON) dropped
_escape_json() {
  # sed collects every line first (the substitutions then see the whole text, line breaks included)
  printf "%s" "$1" | tr -d '\001-\010\013\014\016-\037' |
    sed -e ':a' -e '$!N' -e '$!ba' \
      -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$_TAB/\\\\t/g" -e "s/$_CR/\\\\r/g" -e 's/\n/\\n/g'
}

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

  if ! _exists curl; then
    _err "Cannot send $httpmethod request: curl not found"
    return 1
  fi
  if [ -z "$HTTP_HEADER" ]; then
    _err "Cannot send $httpmethod request: no temp file for the response headers (HTTP_HEADER)"
    return 1
  fi

  # no -L: a moved endpoint must fail instead of curl re-sending the POST as GET
  set -- --silent --dump-header "$HTTP_HEADER" --user-agent "$USER_AGENT" -X "$httpmethod"
  # the container's HTTP_TIMEOUT, else the global one; 0 = no limit
  _post_max_time="${http_timeout:-$HTTP_TIMEOUT}"
  case "$_post_max_time" in
    '' | 0 | *[!0-9]*) ;;
    *) set -- "$@" --max-time "$_post_max_time" ;;
  esac
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

  if ! _exists curl; then
    _err "Cannot send GET request: curl not found"
    return 1
  fi
  if [ -z "$HTTP_HEADER" ]; then
    _err "Cannot send GET request: no temp file for the response headers (HTTP_HEADER)"
    return 1
  fi

  set -- --silent -L --dump-header "$HTTP_HEADER" --user-agent "$USER_AGENT"
  # the container's HTTP_TIMEOUT, else the global one; 0 = no limit
  _get_max_time="${http_timeout:-$HTTP_TIMEOUT}"
  case "$_get_max_time" in
    '' | 0 | *[!0-9]*) ;;
    *) set -- "$@" --max-time "$_get_max_time" ;;
  esac
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

# remove this run's temp files and release its lock
_cleanup() {
  if [ -n "$HTTP_HEADER" ]; then rm -f "$HTTP_HEADER"; fi
  _unlock
}

# pid: 0 when it is a running process (kill -0, or /proc/<pid> for another user's process)
_pid_alive() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2> /dev/null || [ -d "/proc/$1" ]
}

# One run at a time: take the lock LOCK_FILE, a directory holding the PID of the run that owns it. 0 when taken (or
# LOCK_FILE is empty), 1 after an error: another run holds it, or it can't be created. A lock whose run is gone (a
# killed run) is taken over. Never rm -r.
_lock() {
  [ -n "$LOCK_FILE" ] || return 0
  if mkdir "$LOCK_FILE" 2> /dev/null; then
    _lock_own
    return
  fi
  if [ ! -d "$LOCK_FILE" ]; then
    _err "Cannot create the lock LOCK_FILE='$LOCK_FILE'"
    return 1
  fi
  _lk_pid="$(cat "$LOCK_FILE/pid" 2> /dev/null)"
  if [ -z "$_lk_pid" ]; then
    # a run that has just created the lock writes its PID next
    sleep 1
    _lk_pid="$(cat "$LOCK_FILE/pid" 2> /dev/null)"
  fi
  if [ "$_lk_pid" = "$$" ]; then
    # left by an earlier run that had this PID, e.g. PID 1 in a restarted container whose /tmp survived
    _info "Removing the stale lock $LOCK_FILE (it holds this run's own PID $$, left by an earlier run)"
  elif _pid_alive "$_lk_pid"; then
    _err "Another dciu.sh run (PID $_lk_pid) holds the lock $LOCK_FILE"
    return 1
  elif [ -n "$_lk_pid" ]; then
    _info "Removing the stale lock $LOCK_FILE (PID $_lk_pid is not running)"
  else
    _info "Removing the stale lock $LOCK_FILE (no PID in it)"
  fi
  # removed only while it still holds what was read: another run may have taken it over meanwhile
  if [ "$(cat "$LOCK_FILE/pid" 2> /dev/null)" = "$_lk_pid" ]; then
    rm -f "$LOCK_FILE/pid"
    rmdir "$LOCK_FILE" 2> /dev/null
  fi
  if mkdir "$LOCK_FILE" 2> /dev/null; then
    _lock_own || return 1
    # two runs taking over the same stale lock at once: the later removal wins, the run whose PID is no longer in
    # the lock a moment later backs off
    sleep 1
    _lk_pid="$(cat "$LOCK_FILE/pid" 2> /dev/null)"
    if [ "$_lk_pid" = "$$" ]; then
      return 0
    fi
    _lock_owned=""
  else
    _lk_pid="$(cat "$LOCK_FILE/pid" 2> /dev/null)"
  fi
  if [ -n "$_lk_pid" ] && [ "$_lk_pid" != "$$" ] && _pid_alive "$_lk_pid"; then
    _err "Another dciu.sh run (PID $_lk_pid) holds the lock $LOCK_FILE"
  else
    _err "Cannot create the lock LOCK_FILE='$LOCK_FILE'"
  fi
  return 1
}

# the lock directory was just created by this run: its PID goes in
_lock_own() {
  if ! { printf '%s\n' "$$" > "$LOCK_FILE/pid"; } 2> /dev/null; then
    rmdir "$LOCK_FILE" 2> /dev/null
    _err "Cannot create the lock LOCK_FILE='$LOCK_FILE'"
    return 1
  fi
  _lock_owned=1
}

# release the lock this run holds, while it still holds this run's PID
_unlock() {
  [ "$_lock_owned" = 1 ] || return 0
  _lock_owned=""
  if [ "$(cat "$LOCK_FILE/pid" 2> /dev/null)" = "$$" ]; then
    rm -f "$LOCK_FILE/pid"
    rmdir "$LOCK_FILE" 2> /dev/null
  fi
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

# Parse an image name the way Docker does (distribution/reference): the part before the first '/' is a registry when
# the name has a '/' and that part contains a '.' or a ':', is 'localhost' or has an uppercase letter; otherwise the
# image is on Docker Hub, where docker.io, index.docker.io and registry-1.docker.io lead too (a single name gets
# library/). Sets IMAGE_REGISTRY (hub.docker.com for Docker Hub), IMAGE_REGISTRY_API, IMAGE_PATH_FULL (path with
# tag), IMAGE_PATH, IMAGE_NAMESPACE (first path component), IMAGE_REPOSITORY (second), IMAGE_TAG (latest when none)
# and IMAGE_REGISTRY_URL, the image's page for the notification button: empty when the registry host has no dot
# (localhost, registry:5000, [::1]): Telegram refuses such a button URL, which fails the whole message. A digest
# (name@sha256:...) is not part of the tag
parse_image() {
  _pi_name="${1%%@*}"
  _pi_first="${_pi_name%%/*}"
  _pi_path="$_pi_name"
  IMAGE_REGISTRY="hub.docker.com"
  if [ "$_pi_first" != "$_pi_name" ]; then
    case "$_pi_first" in
      *.* | *:* | localhost | *[[:upper:]]*)
        IMAGE_REGISTRY="$_pi_first"
        _pi_path="${_pi_name#*/}"
        ;;
    esac
  fi
  case "$IMAGE_REGISTRY" in
    docker.io | index.docker.io | registry-1.docker.io) IMAGE_REGISTRY="hub.docker.com" ;;
  esac
  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ]; then
    case "$_pi_path" in
      */*) ;;
      *) _pi_path="library/$_pi_path" ;;
    esac
  fi
  IMAGE_REGISTRY_API="$IMAGE_REGISTRY"
  # shellcheck disable=SC2034 # kept for notify modules, like IMAGE_REGISTRY_URL
  IMAGE_PATH_FULL="$_pi_path"

  # the tag follows the last ':' of the last component (a registry port is gone with the registry)
  case "${_pi_path##*/}" in
    *:*)
      IMAGE_TAG="${_pi_path##*:}"
      IMAGE_PATH="${_pi_path%:*}"
      ;;
    *)
      IMAGE_TAG="latest"
      IMAGE_PATH="$_pi_path"
      ;;
  esac
  IMAGE_NAMESPACE="${IMAGE_PATH%%/*}"
  IMAGE_REPOSITORY=""
  case "$IMAGE_PATH" in
    */*)
      IMAGE_REPOSITORY="${IMAGE_PATH#*/}"
      IMAGE_REPOSITORY="${IMAGE_REPOSITORY%%/*}"
      ;;
  esac

  # build registry URL for the image
  # shellcheck disable=SC2034
  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ]; then
    if [ "$IMAGE_NAMESPACE" = "library" ]; then
      IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/_/${IMAGE_REPOSITORY}"
    else
      IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/r/${IMAGE_PATH}"
    fi
  else
    # the host without its port; an IPv6 address ([...]) has no dot either
    case "$IMAGE_REGISTRY" in
      "["*) IMAGE_REGISTRY_URL="" ;;
      *)
        case "${IMAGE_REGISTRY%%:*}" in
          *.*) IMAGE_REGISTRY_URL="https://${IMAGE_REGISTRY}/${IMAGE_PATH}" ;;
          *) IMAGE_REGISTRY_URL="" ;;
        esac
        ;;
    esac
  fi
}

# Detect the image store once per run (IMAGE_STORE): on the containerd image store (Docker Desktop, fresh
# Docker 29 installs) an image ID is the digest of the pulled index/manifest; on the classic store
# (graph drivers) it is the digest of the image config. Unknown counts as classic.
# On the containerd store also IMAGE_IDENTITY=1 when images show their pull record (Identity, Engine API 1.53): a CLI
# speaking an older API (an older daemon, a pinned DOCKER_API_VERSION) shows none for every image, pulled ones too.
# The same docker info call gives INSECURE_REGISTRIES: the registries the daemon lists as not secure (by name).
_init_image_store() {
  IMAGE_STORE="classic"
  IMAGE_IDENTITY=""
  INSECURE_REGISTRIES=""
  # line 1: the storage driver, line 2: the insecure registries
  if ! _iis_info="$(docker info --format '{{json .DriverStatus}}
{{range .RegistryConfig.IndexConfigs}}{{if not .Secure}}{{.Name}} {{end}}{{end}}' 2> /dev/null)"; then
    _iis_info=""
    _debug "Cannot read docker info, assuming the classic image store"
  fi
  _iis_driver="" _iis_insecure=""
  {
    IFS= read -r _iis_driver
    IFS= read -r _iis_insecure
  } << EOF
$_iis_info
EOF
  case "$_iis_driver" in
    *io.containerd.snapshotter*) IMAGE_STORE="containerd" ;;
  esac
  INSECURE_REGISTRIES="${_iis_insecure%"${_iis_insecure##*[![:space:]]}"}"
  _debug "IMAGE_STORE" "$IMAGE_STORE"
  _debug "INSECURE_REGISTRIES" "$INSECURE_REGISTRIES"
  if [ "$IMAGE_STORE" != "containerd" ]; then
    return 0
  fi
  _iis_api="$(docker version --format '{{.Client.APIVersion}} {{.Server.APIVersion}}' 2> /dev/null)"
  _debug "API_VERSION" "$_iis_api"
  if _api_at_least "${_iis_api%% *}" 1 53 && _api_at_least "${_iis_api#* }" 1 53; then
    IMAGE_IDENTITY=1
  fi
  _debug "IMAGE_IDENTITY" "$IMAGE_IDENTITY"
}

# version major minor: 0 when the API version (M.m) is at least major.minor
_api_at_least() {
  case "$1" in
    [0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  _aal_major="${1%%.*}"
  _aal_minor="${1#*.}"
  case "$_aal_major$_aal_minor" in
    *[!0-9]*) return 1 ;;
  esac
  [ "$_aal_major" -gt "$2" ] 2> /dev/null || { [ "$_aal_major" -eq "$2" ] && [ "$_aal_minor" -ge "$3" ]; } 2> /dev/null
}

# image ID: 0 when the image was built, loaded or imported on this host, not pulled from a registry. Classic store: it
# has no RepoDigests (a pull and a push record one). containerd store with IMAGE_IDENTITY: its Identity has no Pull
# entry ("Pull":[{ only appears there: label values are strings, their quotes escaped). 1 otherwise, also when it
# can't be told (containerd without IMAGE_IDENTITY) or the inspect fails
_image_is_local() {
  if [ "$IMAGE_STORE" = "containerd" ]; then
    [ "$IMAGE_IDENTITY" = 1 ] || return 1
    _iil_json="$(docker image inspect --format '{{json .}}' "$1" 2> /dev/null)" || return 1
    [ -n "$_iil_json" ] || return 1
    case "$_iil_json" in
      *'"Pull":[{'*) return 1 ;;
    esac
    return 0
  fi
  _iil_refs="$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$1" 2> /dev/null)" || return 1
  case "$_iil_refs" in
    *[![:space:]]*) return 1 ;;
  esac
  return 0
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

# [image]: with skip_identical_images=true, 0 when image (default $img, the container's tag) points to the container's
# image $image_id or to an identical one (checked right after a pull)
_pulled_image_identical() {
  [ "$skip_identical_images" = "true" ] || return 1
  _pii_id="$(docker image inspect --format '{{.Id}}' "${1:-$img}" 2> /dev/null)" || return 1
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
  if [ "$IMAGE_REGISTRY" = "hub.docker.com" ] && [ "$private_repo" != "true" ]; then
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

# what rc: check_error for a failed curl request to what; curl error 28 within a time limit is HTTP_TIMEOUT's
_curl_reason() {
  _cr_max_time="${http_timeout:-$HTTP_TIMEOUT}"
  case "$2:$_cr_max_time" in
    28: | 28:0 | 28:*[!0-9]*) check_error="cannot reach $1 (curl error $2)" ;;
    28:*) check_error="no answer from $1 within ${_cr_max_time}s (HTTP_TIMEOUT)" ;;
    *) check_error="cannot reach $1 (curl error $2)" ;;
  esac
}

# the Docker Hub and ghcr.io lookups need curl and the temp file for the response headers: without them every lookup
# would look like a registry problem
_require_http() {
  if ! _exists curl; then
    check_error="curl not found (required for Docker Hub and ghcr.io lookups)"
    return 1
  fi
  if [ -z "$HTTP_HEADER" ]; then
    check_error="no temp file for the HTTP response headers (mktemp failed)"
    return 1
  fi
}

# the Docker Hub and ghcr.io responses are read with jq: without it every lookup would look like a registry problem
_require_jq() {
  if _exists jq; then
    return 0
  fi
  check_error="jq not found (required for Docker Hub and ghcr.io lookups)"
  return 1
}

# Docker Hub tags API: the digest of the tag (its index, or its manifest for single-platform images)
_get_dockerhub_digest() {
  _require_http || return 1
  _require_jq || return 1
  _gdd_body="$(_get "https://${IMAGE_REGISTRY_API}/v2/namespaces/${IMAGE_NAMESPACE}/repositories/${IMAGE_REPOSITORY}/tags/${IMAGE_TAG}")"
  _gdd_ret="$?"
  if [ "$_gdd_ret" != "0" ]; then
    _curl_reason "the Docker Hub API" "$_gdd_ret"
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
  _require_http || return 1
  _require_jq || return 1
  if [ -n "$GITHUB_TOKEN" ]; then
    _H1="Authorization: Basic $(printf '%s' "username:$GITHUB_TOKEN" | _base64)"
  elif [ "$private_repo" = "true" ]; then
    check_error="GITHUB_TOKEN must be set for private repository access"
    return 1
  fi

  # the response carries the token: never logged
  _ggd_body="$(_get "https://${IMAGE_REGISTRY_API}/token?scope=repository:${IMAGE_PATH}:pull")"
  _ggd_ret="$?"
  _H1=""
  if [ "$_ggd_ret" != "0" ]; then
    _curl_reason "ghcr.io" "$_ggd_ret"
    return 1
  fi
  _ggd_status="$(_http_status)"
  _debug "status_code" "$_ggd_status"
  if [ "$_ggd_status" != "200" ]; then
    check_error="the ghcr.io token request returned HTTP $_ggd_status"
    # a registry error is JSON with errors[].message (an HTML page from a proxy is only logged)
    _ggd_message="$(printf '%s' "$_ggd_body" | jq -r '.errors[0].message // empty' 2> /dev/null | head -n 1)"
    if [ -n "$_ggd_message" ]; then
      check_error="$check_error: $_ggd_message"
    fi
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
    _curl_reason "ghcr.io" "$_ggd_ret"
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

# options...: _gmd_out = the output of `docker manifest inspect options... $_gmd_img` within HTTP_TIMEOUT (empty when
# it failed); 1 with check_error when it did not finish in time (the shell's "Terminated"/"Killed" stays out)
_gmd_manifest() {
  _gmd_out="$( { _with_timeout "$_gmd_max_time" docker manifest inspect "$@" "$_gmd_img"; } 2> /dev/null)"
  case "$?" in
    0) ;;
    124 | 137 | 143)
      check_error="docker manifest inspect did not finish within ${_gmd_max_time}s (HTTP_TIMEOUT)"
      return 1
      ;;
    *) _gmd_out="" ;;
  esac
}

# TIMEOUT_CMD: 'timeout' when this system has one that works like coreutils' (busybox's before 1.30 needs -t);
# TIMEOUT_KILL=1 when it can also kill (-k): the docker CLI ignores SIGTERM while it waits for a registry
_init_timeout() {
  TIMEOUT_CMD=""
  TIMEOUT_KILL=""
  if timeout -k 1 1 true > /dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
    TIMEOUT_KILL=1
  elif timeout 1 true > /dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
  fi
  _debug "TIMEOUT_CMD" "$TIMEOUT_CMD"
  _debug "TIMEOUT_KILL" "$TIMEOUT_KILL"
}

# secs cmd args...: run cmd under TIMEOUT_CMD when there is one and secs > 0 (killed 2 s after SIGTERM when it ignores
# it), else as is; returns cmd's code: 124 or 143 (busybox) when it was stopped, 137 when it had to be killed
_with_timeout() {
  _wt_secs="$1"
  shift
  case "$_wt_secs" in
    '' | 0 | *[!0-9]*) ;;
    *)
      if [ -n "$TIMEOUT_CMD" ] && [ "$TIMEOUT_KILL" = 1 ]; then
        "$TIMEOUT_CMD" -k 2 "$_wt_secs" "$@"
        return
      elif [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$_wt_secs" "$@"
        return
      fi
      ;;
  esac
  "$@"
}

# registry: 0 when the Docker daemon treats it as insecure (plain HTTP, no TLS verification): localhost, 127.0.0.0/8
# and ::1 (its default CIDRs) and the registries docker info lists as not secure
_registry_insecure() {
  case "$1" in
    localhost | localhost:* | "[::1]" | "[::1]:"*) return 0 ;;
  esac
  # 127.0.0.0/8 as an IPv4 address (127.N.N.N, 1-3 digits each), with or without a :port; a host name like
  # 127.example.com is not one (the daemon resolves names, dciu doesn't: such a registry must be listed by name)
  _ri_host="${1%%:*}"
  case "${1#"$_ri_host"}" in
    : | :*[!0-9]*) _ri_host="" ;;
  esac
  case "$_ri_host" in
    *[!0-9.]* | *..* | *. | *.*.*.*.* | *[0-9][0-9][0-9][0-9]*) ;;
    127.*.*.*) return 0 ;;
  esac
  case " $INSECURE_REGISTRIES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# other registries (and Docker Hub with private_repo): `docker manifest inspect` contacts the registry with the
# credentials of docker login (--insecure for the registries the daemon treats as insecure). With -v it shows the exact
# digest of a single-platform manifest (its Descriptor, the first "digest"); for a list it shows the platforms but not
# the list's digest, so the plain output is hashed (right only for lists pushed by 'docker manifest push')
_get_manifest_digest() {
  _gmd_img="$1"
  set --
  if _registry_insecure "$IMAGE_REGISTRY"; then
    set -- --insecure
  fi
  _gmd_max_time="${http_timeout:-$HTTP_TIMEOUT}"
  _gmd_manifest -v "$@" || return 1
  case "$_gmd_out" in
    "{"*)
      remote_digest="$(printf '%s\n' "$_gmd_out" | awk 'match($0, /"digest": *"sha256:[0-9a-f]+"/) {
        d = substr($0, RSTART, RLENGTH); sub(/^.*sha256:/, "", d); sub(/"$/, "", d); print d; exit }')"
      ;;
    "["*)
      _gmd_manifest "$@" || return 1
      if [ -n "$_gmd_out" ]; then
        remote_digest="$(printf "%s" "$_gmd_out" | sha256sum | awk '{print substr($1, 1, 64)}')"
      fi
      ;;
  esac
  case "$remote_digest" in
    *[!0-9a-f]*) remote_digest="" ;;
  esac
  if [ "${#remote_digest}" != 64 ]; then
    remote_digest=""
    check_error="docker manifest inspect failed"
    return 1
  fi
}

# Check if an update is available for $img, run by the container's image $image_id: sets old_digest (the first
# local digest) and new_digest (prints nothing); the image is up to date when new_digest is any of its digests.
# Returns CHECK_UP_TO_DATE, CHECK_UPDATE_AVAILABLE, CHECK_FAILED (check_error says why) or, with
# skip_local_images=true, CHECK_LOCAL_IMAGE (local_reason says why)
check_update() {
  old_digest=""
  new_digest=""
  check_error=""
  local_reason=""

  if ! get_local_digests "$image_id"; then
    check_error="cannot inspect the container's image $image_id"
    return "$CHECK_FAILED"
  fi
  # built or loaded here: nothing on a registry to compare with (classic store: the RepoDigests just read)
  if [ "$skip_local_images" = "true" ]; then
    if { [ "$IMAGE_STORE" = "containerd" ] && _image_is_local "$image_id"; } ||
      { [ "$IMAGE_STORE" != "containerd" ] && [ -z "$local_digests" ]; }; then
      local_reason="the image was built or loaded locally, not pulled from a registry"
      return "$CHECK_LOCAL_IMAGE"
    fi
  fi
  _cu_tag_id=""
  if [ "$skip_identical_images" = "true" ] || [ "$skip_local_images" = "true" ]; then
    _cu_tag_id="$(docker image inspect --format '{{.Id}}' "$img" 2> /dev/null)"
  fi
  if [ -n "$_cu_tag_id" ] && [ "$_cu_tag_id" != "$image_id" ]; then
    # a local build tagged over the container's tag: a pull would take the tag away from it
    if [ "$skip_local_images" = "true" ] && _image_is_local "$_cu_tag_id"; then
      local_reason="the tag $img now points to an image built or loaded locally"
      return "$CHECK_LOCAL_IMAGE"
    fi
    # the tag may point to an image identical to the container's (pulled after a re-publish, the recreate skipped):
    # its digests are the container's too
    if [ "$skip_identical_images" = "true" ] && _same_image_content "$image_id" "$_cu_tag_id"; then
      _add_image_digests "$_cu_tag_id"
    fi
  fi
  _debug "local_digests" "$local_digests"
  if [ -z "$local_digests" ]; then
    check_error="the image has no registry digest (built or loaded locally?), set the label $LABEL_SKIP_LOCAL_IMAGES=true or $LABEL_MODE=none to skip this container"
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

# Read container cid with one docker inspect: sets name, img, image_id, running, the settings (container label,
# else global config, else default; see _container_setting) and the Swarm/Compose labels. An invalid mode label is
# left in label_error_mode, the other invalid labels in label_errors (label_error_count of them).
# Returns 1 when docker inspect fails, 2 when a value contains a line break (the output has one value per line).
_read_container() {
  _rc_cid="$1"

  # one value per line, in the order they are read below; the last line marks a complete, unshifted read.
  # dciu's own labels come with their line breaks as spaces (YAML block scalars end with one)
  _rc_format="{{.Name}}
{{.Config.Image}}
{{.Image}}
{{.State.Running}}
{{join (split (index .Config.Labels \"$LABEL_MODE\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_UPDATE_STOPPED\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_START_STOPPED\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_PRUNE_DANGLING\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_UPDATE_COMPOSE\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_PRIVATE_REPO\") \"\\n\") \" \"}}
{{index .Config.Labels \"com.docker.stack.namespace\"}}
{{index .Config.Labels \"com.docker.compose.project\"}}
{{index .Config.Labels \"com.docker.compose.service\"}}
{{index .Config.Labels \"com.docker.compose.project.config_files\"}}
{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}
{{index .Config.Labels \"com.docker.compose.project.environment_file\"}}
{{index .Config.Labels \"com.docker.compose.oneoff\"}}
{{join (split (index .Config.Labels \"$LABEL_COMPOSE_RECREATE\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_COMPOSE_BUILD\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_SKIP_IDENTICAL_IMAGES\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_SKIP_LOCAL_IMAGES\") \"\\n\") \" \"}}
{{join (split (index .Config.Labels \"$LABEL_HTTP_TIMEOUT\") \"\\n\") \" \"}}
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
    IFS= read -r _rc_private_repo
    IFS= read -r stack_ns
    IFS= read -r compose_project
    IFS= read -r compose_service
    IFS= read -r compose_file
    IFS= read -r compose_working_dir
    IFS= read -r compose_env_files
    IFS= read -r compose_oneoff
    IFS= read -r _rc_compose_recreate
    IFS= read -r _rc_compose_build
    IFS= read -r _rc_skip_identical
    IFS= read -r _rc_skip_local
    IFS= read -r _rc_http_timeout
    IFS= read -r _rc_end
    # a line break in a value shifts every later line: nothing may follow the end marker
    if IFS= read -r _rc_more; then _rc_end=""; fi
  } << EOF
$_rc_out
EOF
  # the name is the first line: never shifted
  name="${_rc_name#/}"
  if [ "$_rc_end" != "dciu-inspect-end" ]; then
    return 2
  fi

  label_error_mode=""
  label_errors=""
  label_error_count=0
  if _container_setting mode MODE "$LABEL_MODE" "$_rc_mode"; then
    mode="$_sv"
  else
    # shown as set, e.g. in the check_failed notification
    mode="$_cs_value"
    label_error_mode="$_cs_error"
  fi
  _rc_setting bool UPDATE_STOPPED "$LABEL_UPDATE_STOPPED" "$_rc_update_stopped"
  update_stopped="$_sv"
  _rc_setting bool START_STOPPED "$LABEL_START_STOPPED" "$_rc_start_stopped"
  start_stopped="$_sv"
  _rc_setting bool PRUNE_DANGLING "$LABEL_PRUNE_DANGLING" "$_rc_prune_dangling"
  prune_dangling="$_sv"
  _rc_setting bool UPDATE_COMPOSE "$LABEL_UPDATE_COMPOSE" "$_rc_update_compose"
  update_compose="$_sv"
  _rc_setting bool PRIVATE_REPO "$LABEL_PRIVATE_REPO" "$_rc_private_repo"
  private_repo="$_sv"
  _rc_setting bool SKIP_IDENTICAL_IMAGES "$LABEL_SKIP_IDENTICAL_IMAGES" "$_rc_skip_identical"
  skip_identical_images="$_sv"
  _rc_setting bool SKIP_LOCAL_IMAGES "$LABEL_SKIP_LOCAL_IMAGES" "$_rc_skip_local"
  skip_local_images="$_sv"
  _rc_setting seconds HTTP_TIMEOUT "$LABEL_HTTP_TIMEOUT" "$_rc_http_timeout"
  http_timeout="$_sv"

  _debug "container" "$name ($_rc_cid)"
  _debug "image" "$img"
  _debug "mode" "$mode"
  _debug "update_stopped" "$update_stopped"
  _debug "start_stopped" "$start_stopped"
  _debug "prune_dangling" "$prune_dangling"
  _debug "update_compose" "$update_compose"
  _debug "private_repo" "$private_repo"
  _debug "skip_identical_images" "$skip_identical_images"
  _debug "skip_local_images" "$skip_local_images"
  _debug "http_timeout" "$http_timeout"

  # the compose labels only matter (and are only checked) for a Compose container
  if [ -n "$compose_project" ]; then
    _rc_setting recreate COMPOSE_RECREATE "$LABEL_COMPOSE_RECREATE" "$_rc_compose_recreate"
    compose_recreate="$_sv"
    _rc_setting bool COMPOSE_BUILD "$LABEL_COMPOSE_BUILD" "$_rc_compose_build"
    compose_build="$_sv"
    _debug "compose_recreate" "$compose_recreate"
    _debug "compose_build" "$compose_build"
  fi
}

# type NAME label_name label_value: _container_setting for _read_container, an invalid label added to label_errors
_rc_setting() {
  if ! _container_setting "$@"; then
    label_errors="${label_errors:+$label_errors, }$_cs_error"
    label_error_count=$((label_error_count + 1))
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

# image: the pulled image is identical to the running one, so the container is left alone; returns 0
_identical_skipped() {
  _update_skipped "Skipping container $name ($1): the pulled image is identical to the running one (the registry re-published the tag without changes)"
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

  # a 'docker compose run' container carries its service's labels, but 'up' recreates only the service's own
  # containers: for a one-off it would restart the service on every run, or replace it with a stopped container
  if [ "$compose_oneoff" = "True" ]; then
    _update_skipped "Skipping container $name ($img) [Service \"$compose_service\"] in Docker Compose project $compose_project ($compose_file): one-off container (docker compose run), not recreated by docker compose up"
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
  # the image the Compose file names now: when its image: changed after the container was created, the pull fetched
  # that one, not the container's tag. Read from the service's own entry (config --images lists its depends_on
  # services' images too); the container's own image name when compose or jq can't say
  _ucs_image=""
  if _exists jq; then
    _ucs_image="$(_compose config --format json "$compose_service" 2> /dev/null |
      jq -r --arg s "$compose_service" '.services[$s].image // empty' 2> /dev/null)"
  fi
  if [ -z "$_ucs_image" ]; then
    _ucs_image="$img"
  fi
  _info "Successfully updated image $_ucs_image for container $_ucs_ctr"

  if _pulled_image_identical "$_ucs_image"; then
    _identical_skipped "$_ucs_image"
    return 0
  fi

  _ucs_start=""
  if [ "$running" = "true" ] || [ "$start_stopped" = "true" ]; then
    _ucs_start=1
  elif [ "$compose_recreate" != "stack" ] && [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$compose_project" --filter "label=com.docker.compose.service=$compose_service" --filter "label=com.docker.compose.oneoff=False" --filter status=running 2> /dev/null)" ]; then
    # up recreates every container of the service: with another one running (a scaled service), --no-start would
    # stop the service
    _ucs_start=1
  fi
  if [ -n "$_ucs_start" ]; then
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
  # up replaces the containers it recreates (new IDs); this one is still there when up left it out
  # (e.g. COMPOSE_RECREATE=stack and its service is in a Compose profile that isn't enabled)
  if [ -n "$(docker ps -aq --filter "id=$cid" 2> /dev/null)" ]; then
    _update_failed "Error recreating container $_ucs_ctr: docker compose up did not replace it"
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
    _identical_skipped "$img"
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
      # dciu's own labels can't cause this (their line breaks are read as spaces), Compose's and Swarm's can
      if [ -n "$name" ]; then
        _err "Cannot read the settings of container $name ($cid): a label value contains a line break"
      else
        _err "Cannot read the settings of container $cid: a label value contains a line break"
      fi
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

  # before any notification: the notify modules link to IMAGE_REGISTRY_URL (only parameter expansion, no lookups)
  parse_image "$img"

  # an invalid mode label: dciu can't tell whether the container may be touched at all
  if [ -n "$label_error_mode" ]; then
    check_error="invalid label $label_error_mode"
    _check_failed
    return 1
  fi

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

  # the other invalid labels: none of them may silently fall back to a value the label was meant to override
  if [ -n "$label_errors" ]; then
    if [ "$label_error_count" -gt 1 ]; then
      check_error="invalid labels $label_errors"
    else
      check_error="invalid label $label_errors"
    fi
    _check_failed
    return 1
  fi

  # Check for update
  check_update
  _pc_check="$?"
  if [ "$_pc_check" = "$CHECK_FAILED" ]; then
    _check_failed
    return 1
  fi
  if [ "$_pc_check" = "$CHECK_LOCAL_IMAGE" ]; then
    _info "Skipping container $name ($img): $local_reason"
    return 0
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

  # after the LOG_FILE check, so an invalid setting is also reported in the log file
  _init_settings

  # One temp file per run for the response headers of _post/_get, never one inherited from the environment.
  # The traps are set before it is created, so the EXIT trap deletes it however the run ends.
  # Without it registry lookups and notifications fail, but every container is still processed.
  HTTP_HEADER=""
  trap '_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 131' QUIT
  trap 'exit 141' PIPE
  trap 'exit 143' TERM
  _inithttp

  # one run at a time (LOCK_FILE not set: the default; set to empty: no lock). Released by the EXIT trap too, and
  # here before every return: a main run inside a command substitution can't count on that subshell's EXIT trap
  if [ -z "${LOCK_FILE+set}" ]; then
    LOCK_FILE="$DEFAULT_LOCK_FILE"
  fi
  if ! _lock; then
    return 1
  fi

  # Get all containers
  if ! cids="$(docker ps -q -a)"; then
    _err "Cannot list containers"
    _unlock
    return 1
  fi
  _init_image_store
  _init_timeout

  # like acme.sh's cron: 1 when a setting was invalid or any container's check or update failed (skips and failed
  # notifications don't count)
  _main_ret="$_settings_invalid"
  for cid in $cids; do
    if ! (process_container "$cid"); then
      _main_ret=1
    fi
  done
  _info "All containers processed."
  _unlock
  return "$_main_ret"
}

main
