#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# notify-email.sh — send one autofix digest by email
#
#   bash ci/notify-email.sh "SUBJECT" < body.txt
#
# Used by two callers that both already know something happened, so this script
# never decides whether an event is worth reporting:
#   - .github/workflows/autofix.yml  (the fix and drift-release jobs, which only
#     exist when an app has an open issue or an unreleased fix)
#   - watchdog.sh                    (notify_user, which only fires when the
#     alert array is non-empty)
# Hooking it anywhere upstream of those gates — cron, or the hourly scan job —
# is what would turn this into an hourly "nothing happened" mail.
#
# Configuration comes from the environment; on the Mac, cron has almost no
# environment, so ~/.autofix-mail.env is sourced when present:
#   AUTOFIX_MAIL_TO     recipient (required)
#   AUTOFIX_MAIL_USER   SMTP username (required)
#   AUTOFIX_MAIL_PASS   SMTP password — a Gmail *app password*, never the real
#                       account password (required)
#   AUTOFIX_MAIL_FROM   defaults to AUTOFIX_MAIL_USER
#   AUTOFIX_MAIL_HOST   defaults to smtp.gmail.com
#   AUTOFIX_MAIL_PORT   defaults to 465 (implicit TLS; 587 uses STARTTLS)
#
# Missing configuration is not an error. A worker that fixed a bug must not be
# reported as failed because mail was never set up, so every failure path here
# warns and exits 0.
###############################################################################

MAIL_ENV="${AUTOFIX_MAIL_ENV:-$HOME/.autofix-mail.env}"
# shellcheck disable=SC1090
[ -f "$MAIL_ENV" ] && . "$MAIL_ENV"

subject="${1:-[autofix] notification}"

: "${AUTOFIX_MAIL_HOST:=smtp.gmail.com}"
: "${AUTOFIX_MAIL_PORT:=465}"
: "${AUTOFIX_MAIL_TO:=}"
: "${AUTOFIX_MAIL_USER:=}"
: "${AUTOFIX_MAIL_PASS:=}"
: "${AUTOFIX_MAIL_FROM:=$AUTOFIX_MAIL_USER}"

if [ -z "$AUTOFIX_MAIL_TO" ] || [ -z "$AUTOFIX_MAIL_USER" ] || [ -z "$AUTOFIX_MAIL_PASS" ]; then
    echo "notify-email: not configured (need AUTOFIX_MAIL_TO/USER/PASS) — skipping" >&2
    cat > /dev/null   # drain stdin so the caller's pipe does not break
    exit 0
fi

export AUTOFIX_MAIL_HOST AUTOFIX_MAIL_PORT AUTOFIX_MAIL_TO \
       AUTOFIX_MAIL_USER AUTOFIX_MAIL_PASS AUTOFIX_MAIL_FROM
export AUTOFIX_MAIL_SUBJECT="$subject"

# The password goes through the environment, not argv — argv is world-readable
# in ps output on a shared runner.
python3 - <<'PY'
import os, smtplib, ssl, sys
from email.message import EmailMessage

body = sys.stdin.read() or "(no body)"

msg = EmailMessage()
msg["Subject"] = os.environ["AUTOFIX_MAIL_SUBJECT"]
msg["From"]    = os.environ["AUTOFIX_MAIL_FROM"]
msg["To"]      = os.environ["AUTOFIX_MAIL_TO"]
msg.set_content(body)

host = os.environ["AUTOFIX_MAIL_HOST"]
port = int(os.environ["AUTOFIX_MAIL_PORT"])
user = os.environ["AUTOFIX_MAIL_USER"]
pw   = os.environ["AUTOFIX_MAIL_PASS"]

try:
    ctx = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=30) as s:
            s.login(user, pw)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=30) as s:
            s.starttls(context=ctx)
            s.login(user, pw)
            s.send_message(msg)
    print("notify-email: sent to %s" % os.environ["AUTOFIX_MAIL_TO"], file=sys.stderr)
except Exception as exc:
    # Deliberately not fatal: see the header note.
    print("notify-email: send failed: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
PY
exit 0
