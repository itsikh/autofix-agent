#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# status-lines.sh — extract the worker's event lines from a run log
#
#   bash ci/status-lines.sh path/to/app.log
#
# One regex, two callers: the workflow's Summary step (which prints it to a
# public job log) and the email digest. Keeping it here means an event that is
# added to worker.sh gets reported in both places or neither, rather than
# silently appearing in one.
#
# These are dispatcher/worker status lines only — no file contents, no diffs,
# which is what makes them safe to print in a public repo's job log. ERROR: is
# included deliberately: a hidden failure is far worse than the small amount of
# context an error message reveals.
#
# Each alternative below corresponds to an event worth being told about:
#   Processing   a ticket was picked up          Labelled  first failure, now flagged
#   Fix          a fix was committed             Released  a version was published
#   Closed       the ticket was handled          ERROR:    anything that went wrong,
#   ===          run start/finish verdict                  including "All N attempts
#   Task/Issue/Build/Pushed/Acquired/No/Skipping             failed" and UNRELEASED
###############################################################################

LOG="${1:?usage: status-lines.sh <logfile>}"

grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] \[[a-z0-9-]+\] (ERROR|===|Task |Issue |Build |Processing |Fix |Labelled |Pushed|Closed|No |Acquired|Released|Skipping)' \
    "$LOG"
