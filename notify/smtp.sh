#!/usr/bin/env sh

# SMTP notify module for dciu.sh

# This implementation uses either curl or Python (3 or 2.7).

# Required environment variables:
# SMTP_FROM="from@example.com"  # required
# SMTP_TO="to@example.com"      # required
# SMTP_HOST="smtp.example.com"  # required
# Optional environment variables:
# SMTP_PORT="25"                # defaults to 25, 465 or 587 depending on SMTP_SECURE
# SMTP_SECURE="tls"             # one of "none","ssl" (implicit TLS, TLS Wrapper),"tls" (explicit TLS, STARTTLS); default tls
# SMTP_USERNAME=""              # set if SMTP server requires login
# SMTP_PASSWORD=""              # set if SMTP server requires login
# SMTP_TIMEOUT="30"             # seconds for SMTP operations to timeout; default 30, 0 = no limit
# SMTP_BIN=""                   # command to use; default finds first of python3, python2.7, python, pypy3, pypy, curl on PATH

smtp_send() {
  # Arguments: event, container name, image, old digest, new digest, mode, running state, message
  event="$1"
  container="$2"
  image="$3"
  old_digest="$4"
  new_digest="$5"
  mode="$6"
  running="$7"
  message="$8"

  SMTP_SECURE_DEFAULT="tls"
  SMTP_TIMEOUT_DEFAULT="30"

  # find or validate SMTP_BIN
  if [ -n "$SMTP_BIN" ] && ! _exists "$SMTP_BIN"; then
    _err "SMTP_BIN '$SMTP_BIN' not found"
    return 1
  fi
  if [ -z "$SMTP_BIN" ]; then
    # Look for a command that can communicate with an SMTP server.
    for cmd in python3 python2.7 python pypy3 pypy curl; do
      if _exists "$cmd"; then
        SMTP_BIN="$cmd"
        break
      fi
    done
    if [ -z "$SMTP_BIN" ]; then
      _err "smtp notify requires curl or Python, but can't find any."
      _err 'If you have one of them, define SMTP_BIN="/path/to/curl_or_python".'
      return 1
    fi
  fi
  _debug "SMTP_BIN" "$SMTP_BIN"

  # Strip CR and NL from text to prevent MIME header injection
  # text
  _clean_email_header() {
    printf "%s" "$1" | tr -d "\r\n"
  }

  # Simple check for display name in an email address (< > or ")
  # email
  _email_has_display_name() {
    _email="$1"
    printf "%s\n" "$_email" | grep -q -E '^.*[<>"]'
  }

  # validate required configs
  SMTP_FROM="$(_clean_email_header "$SMTP_FROM")"
  if [ -z "$SMTP_FROM" ]; then
    _err "You must define SMTP_FROM as the sender email address."
    return 1
  fi
  if _email_has_display_name "$SMTP_FROM"; then
    _err "SMTP_FROM must be only a simple email address (sender@example.com)."
    _err "Change your SMTP_FROM='$SMTP_FROM' to remove the display name."
    return 1
  fi
  _debug "SMTP_FROM" "$SMTP_FROM"

  SMTP_TO="$(_clean_email_header "$SMTP_TO")"
  if [ -z "$SMTP_TO" ]; then
    _err "You must define SMTP_TO as the recipient email address(es)."
    return 1
  fi
  if _email_has_display_name "$SMTP_TO"; then
    _err "SMTP_TO must be only simple email addresses (to@example.com,to2@example.com)."
    _err "Change your SMTP_TO='$SMTP_TO' to remove the display name(s)."
    return 1
  fi
  _debug "SMTP_TO" "$SMTP_TO"

  if [ -z "$SMTP_HOST" ]; then
    _err "You must define SMTP_HOST as the SMTP server hostname."
    return 1
  fi
  _debug "SMTP_HOST" "$SMTP_HOST"

  if [ -z "$SMTP_SECURE" ]; then SMTP_SECURE="$SMTP_SECURE_DEFAULT"; fi

  # choose default port
  case "$SMTP_SECURE" in
    "none") smtp_port_default="25" ;;
    "ssl") smtp_port_default="465" ;;
    "tls") smtp_port_default="587" ;;
    *)
      _err "Invalid SMTP_SECURE='$SMTP_SECURE'. It must be 'ssl', 'tls' or 'none'."
      return 1
      ;;
  esac
  _debug "SMTP_SECURE" "$SMTP_SECURE"

  if [ -z "$SMTP_PORT" ]; then SMTP_PORT="$smtp_port_default"; fi
  case "$SMTP_PORT" in
    *[!0-9]*)
      _err "Invalid SMTP_PORT='$SMTP_PORT'. It must be a port number."
      return 1
      ;;
  esac
  _debug "SMTP_PORT" "$SMTP_PORT"

  _debug "SMTP_USERNAME" "$SMTP_USERNAME"
  _secure_debug "SMTP_PASSWORD" "$SMTP_PASSWORD"

  if [ -z "$SMTP_TIMEOUT" ]; then SMTP_TIMEOUT="$SMTP_TIMEOUT_DEFAULT"; fi
  case "$SMTP_TIMEOUT" in
    *[!0-9]*)
      _err "Invalid SMTP_TIMEOUT='$SMTP_TIMEOUT'. It must be a number of seconds (0 = no limit)."
      return 1
      ;;
  esac
  _debug "SMTP_TIMEOUT" "$SMTP_TIMEOUT"

  SMTP_X_MAILER="$(_clean_email_header "$PROJECT_NAME $VER --notify-hook smtp ($SMTP_BIN)")"

  # Careful: this may include SMTP_PASSWORD in plaintext!
  if [ "${DEBUG:-$DEBUG_LEVEL_NONE}" -ge "$DEBUG_LEVEL_2" ]; then
    SMTP_SHOW_TRANSCRIPT="True"
  else
    SMTP_SHOW_TRANSCRIPT=""
  fi

  SMTP_SUBJECT="[dciu.sh] Container \"$container\" on $NOTIFY_SOURCE: $event"
  SMTP_SUBJECT=$(_clean_email_header "$SMTP_SUBJECT")
  _debug "SMTP_SUBJECT" "$SMTP_SUBJECT"

  content=$(
    cat << EOF
Container: $container
Image: $image
Old Digest: ${old_digest:-unknown}
New Digest: ${new_digest:-unknown}
Running: $running
Mode: $mode
Message: $message
Source: $NOTIFY_SOURCE
EOF
  )

  # no CR in the body: SMTP allows CR only as part of a line break (curl --crlf leaves a lone CR as it is)
  SMTP_CONTENT="$(printf "%s" "$content" | tr -d '\r')"
  _debug2 "SMTP_CONTENT" "$SMTP_CONTENT"

  ##
  ## curl smtp sending
  ##

  # Convert text to RFC-2047 MIME "encoded word" format if it contains non-ASCII chars
  # text
  # shellcheck disable=SC2317,SC2329
  _mime_encoded_word() {
    _text="$1"
    # (regex character ranges like [a-z] can be locale-dependent; enumerate ASCII chars to avoid that)
    _ascii='] $`"'"[!#%&'()*+,./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ~^_abcdefghijklmnopqrstuvwxyz{|}~-"
    if printf "%s\n" "$_text" | grep -q -E "^.*[^$_ascii]"; then
      # At least one non-ASCII char; convert entire thing to encoded word
      printf "%s" "=?UTF-8?B?$(printf "%s" "$_text" | _base64)?="
    else
      # Just printable ASCII, no conversion needed
      printf "%s" "$_text"
    fi
  }

  # Output current date in RFC-2822 Section 3.3 format as required in email headers
  # (e.g., "Mon, 15 Feb 2021 14:22:01 -0800")
  # shellcheck disable=SC2317,SC2329
  _rfc2822_date() {
    # Notes:
    #   - this is deliberately not UTC, because it "SHOULD express local time" per spec
    #   - the spec requires weekday and month in the C locale (English), not localized
    #   - this date format specifier has been tested on Linux, Mac, Solaris and FreeBSD
    #   - LC_ALL: it overrides LANG and an LC_TIME from the environment
    LC_ALL=C date +'%a, %-d %b %Y %H:%M:%S %z'
  }

  # Output an RFC-822 / RFC-5322 email message using SMTP_* variables.
  # (This assumes variables have already been cleaned for use in email headers.)
  # shellcheck disable=SC2317,SC2329
  _smtp_raw_message() {
    printf "%s\n" "From: $SMTP_FROM"
    printf "%s\n" "To: $SMTP_TO"
    printf "%s\n" "Subject: $(_mime_encoded_word "$SMTP_SUBJECT")"
    printf "%s\n" "Date: $(_rfc2822_date)"
    printf "%s\n" "MIME-Version: 1.0"
    printf "%s\n" "Content-Type: text/plain; charset=utf-8"
    printf "%s\n" "Content-Transfer-Encoding: 8bit"
    printf "%s\n" "X-Mailer: $SMTP_X_MAILER"
    printf "\n"
    printf "%s\n" "$SMTP_CONTENT"
  }

  # Send the message via curl using SMTP_* variables
  # shellcheck disable=SC2317,SC2329
  _smtp_send_curl() {
    # Build curl args in $@
    case "$SMTP_SECURE" in
      none)
        set -- --url "smtp://${SMTP_HOST}:${SMTP_PORT}"
        ;;
      ssl)
        set -- --url "smtps://${SMTP_HOST}:${SMTP_PORT}"
        ;;
      tls)
        set -- --url "smtp://${SMTP_HOST}:${SMTP_PORT}" --ssl-reqd
        ;;
      *)
        # This will only occur if someone adds a new SMTP_SECURE option above
        # without updating this code for it.
        _err "Unhandled SMTP_SECURE='$SMTP_SECURE' in _smtp_send_curl"
        _err "Please re-run with DEBUG=1 and report a bug."
        return 1
        ;;
    esac

    # --crlf: SMTP needs CRLF line endings (a bare LF can be refused, and a line that is just "." is only escaped
    # after a CRLF, so it would end the mail early)
    set -- "$@" \
      --upload-file - \
      --crlf \
      --mail-from "$SMTP_FROM"
    # 0 (any number of zeros) = no limit
    case "$SMTP_TIMEOUT" in
      *[!0]*) set -- "$@" --max-time "$SMTP_TIMEOUT" ;;
    esac

    # Burst comma-separated $SMTP_TO into individual --mail-rcpt args.
    _to="${SMTP_TO},"
    while [ -n "$_to" ]; do
      _rcpt="${_to%%,*}"
      _to="${_to#*,}"
      set -- "$@" --mail-rcpt "$_rcpt"
    done

    _smtp_login="${SMTP_USERNAME}:${SMTP_PASSWORD}"
    if [ "$_smtp_login" != ":" ]; then
      set -- "$@" --user "$_smtp_login"
    fi

    if [ "$SMTP_SHOW_TRANSCRIPT" = "True" ]; then
      set -- "$@" --verbose
    else
      set -- "$@" --silent --show-error
    fi

    raw_message="$(_smtp_raw_message)"

    # the arguments include --user with SMTP_PASSWORD
    _secure_debug2 "curl args" "$*"
    _debug3 "raw_message" "$raw_message"

    printf "%s\n" "$raw_message" | "$SMTP_BIN" "$@"
  }

  ##
  ## Python smtp sending
  ##

  # Send the message via Python using SMTP_* variables
  # shellcheck disable=SC2317,SC2329
  _smtp_send_python() {
    _debug "Python version" "$("$SMTP_BIN" --version 2>&1)"

    # every value goes into a """...""" literal: backslashes, quotes and line breaks escaped (the JSON escapes are
    # valid Python string escapes too), so a message or password can't end the literal early
    _py_show_transcript="$(_escape_json "$SMTP_SHOW_TRANSCRIPT")"
    _py_host="$(_escape_json "$SMTP_HOST")"
    _py_port="$(_escape_json "$SMTP_PORT")"
    _py_secure="$(_escape_json "$SMTP_SECURE")"
    _py_username="$(_escape_json "$SMTP_USERNAME")"
    _py_password="$(_escape_json "$SMTP_PASSWORD")"
    _py_timeout="$(_escape_json "$SMTP_TIMEOUT")"
    _py_x_mailer="$(_escape_json "$SMTP_X_MAILER")"
    _py_from="$(_escape_json "$SMTP_FROM")"
    _py_to="$(_escape_json "$SMTP_TO")"
    _py_subject="$(_escape_json "$SMTP_SUBJECT")"
    _py_content="$(_escape_json "$SMTP_CONTENT")"

    # language=Python
    "$SMTP_BIN" << PYTHON
# This code is meant to work with either Python 2.7.x or Python 3.4+.
try:
    try:
        from email.message import EmailMessage
        from email.policy import default as email_policy_default
    except ImportError:
        # Python 2 (or < 3.3)
        from email.mime.text import MIMEText as EmailMessage
        email_policy_default = None
    from email.utils import formatdate as rfc2822_date
    from smtplib import SMTP, SMTP_SSL, SMTPException
    from socket import error as SocketError
except ImportError as err:
    print("A required Python standard package is missing. This system may have"
          " a reduced version of Python unsuitable for sending mail: %s" % err)
    exit(1)

show_transcript = """$_py_show_transcript""" == "True"

smtp_host = """$_py_host"""
smtp_port = int("""$_py_port""")
smtp_secure = """$_py_secure"""
username = """$_py_username"""
password = """$_py_password"""
timeout = int("""$_py_timeout""") or None  # seconds, 0 = no limit
x_mailer="""$_py_x_mailer"""

from_email="""$_py_from"""
to_emails="""$_py_to"""  # can be comma-separated
subject="""$_py_subject"""
content="""$_py_content"""

try:
    msg = EmailMessage(policy=email_policy_default)
    msg.set_content(content)
except (AttributeError, TypeError):
    # Python 2 MIMEText
    msg = EmailMessage(content)
msg["Subject"] = subject
msg["From"] = from_email
msg["To"] = to_emails
msg["Date"] = rfc2822_date(localtime=True)
msg["X-Mailer"] = x_mailer

smtp = None
try:
    if smtp_secure == "ssl":
        smtp = SMTP_SSL(smtp_host, smtp_port, timeout=timeout)
    else:
        smtp = SMTP(smtp_host, smtp_port, timeout=timeout)
    smtp.set_debuglevel(show_transcript)
    if smtp_secure == "tls":
        smtp.starttls()
    if username or password:
        smtp.login(username, password)
    smtp.sendmail(msg["From"], msg["To"].split(","), msg.as_string())

except SMTPException as err:
    # Output just the error (skip the Python stack trace) for SMTP errors
    print("Error sending: %r" % err)
    exit(1)

except SocketError as err:
    print("Error connecting to %s:%d: %r" % (smtp_host, smtp_port, err))
    exit(1)

finally:
    if smtp is not None:
        smtp.quit()
PYTHON
  }

  # Send the message:
  case "$(basename "$SMTP_BIN")" in
    curl) _smtp_send=_smtp_send_curl ;;
    py*) _smtp_send=_smtp_send_python ;;
    *)
      _err "Can't figure out how to invoke '$SMTP_BIN'."
      _err "Check your SMTP_BIN setting."
      return 1
      ;;
  esac

  if ! smtp_output="$($_smtp_send)"; then
    _err "Error sending message with $SMTP_BIN."
    if [ -n "$smtp_output" ]; then
      _err "$smtp_output"
    fi
    return 1
  fi

  return 0
}
