# autofix-agent

Unified autonomous bug-fixing agent for Android apps. A single codebase replaces all per-app autofix scripts — new apps register by adding a `.conf` file.

Runs in **two places at once** — see [docs/CLOUD.md](docs/CLOUD.md):

| | Where | Interval |
|---|---|---|
| Local | your Mac, via `cron` | every 5 min |
| Cloud | GitHub Actions (free) | hourly |

It emails a digest whenever a run actually does something — see
[docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md).

They share work safely via the `claude-active` GitHub label, which acts as a
cross-machine lock. If the Mac is asleep, the cloud run picks the work up.

## How it works

```
LOCAL — cron (every 5 min)
  └── wrapper.sh         ← meta-wrapper with self-healing
        └── agent.sh     ← dispatcher: checks all apps for open issues
              ├── worker.sh apps/mychef.conf     ┐
              ├── worker.sh apps/mylock.conf      ├─ parallel (max 3)
              └── worker.sh apps/medreminder.conf ┘

cron (every 30 min)
  └── watchdog.sh        ← health monitor & macOS notifier

CLOUD — .github/workflows/autofix.yml (hourly)
  └── scan   ← agent.sh --list-json (no clones, ~1 min when idle)
        └── fix  ← matrix, one job per app with work
              ├── ci/clone-app.sh apps/<slug>.conf
              └── worker.sh apps/<slug>.conf
```

1. **`agent.sh`** reads every `apps/*.conf` file, quick-checks GitHub for open `autofix`-labelled issues, then runs `worker.sh` for each app that has open issues — up to `MAX_PARALLEL` (default 3) at once.

2. **`worker.sh`** is the core fix loop (based on [MyLock's Gen3 autofix.sh](https://github.com/itsikh/mylock)):
   - Acquires a per-app file lock
   - Syncs git state (fetch, rebase, push)
   - Groups issues by `story:*` label
   - For each task: prompts Claude CLI to fix, verifies the build, commits, closes the issue on GitHub
   - After all tasks: triggers `/release`
   - While Claude is out of quota, fixes run on Freebuff instead and `/release` waits — see [Freebuff fallback](#freebuff-fallback)

3. **`wrapper.sh`** catches `agent.sh` failures, asks Claude to diagnose and fix the script itself, then retries (up to 2 meta-retries).

4. **`watchdog.sh`** runs every 30 minutes: checks log freshness, detects consecutive failures, kills stale processes, cleans stale locks, and sends macOS notifications for issues it cannot auto-fix.

## Quick start

```bash
# 1. Clone
git clone git@github.com:itsikh/autofix-agent.git ~/dev/autofix-agent
cd ~/dev/autofix-agent

# 2. Install (sets up cron, makes scripts executable)
./install.sh

# 3. Verify
crontab -l
tail -f logs/cron.log
```

## Registering a new app

Create `apps/<slug>.conf`:

```bash
# Required
APP_SLUG="myapp"
PROJECT_DIR="/Users/you/dev/MyApp"
BUGS_REPO="itsikh/myapp-releases"

# Optional (these are the defaults)
LOCK_SLUG="myapp"            # lock dir: /tmp/<LOCK_SLUG>-autofix.lockdir
GIT_REMOTES="auto"           # "auto" = git remote, or space-separated: "origin bitbucket"
PROMPT_FILE="android-default" # relative to prompts/ (without .txt)
RELEASE_MODE="skill"         # "skill" (call /release) | "none" | "manual"
BUILD_TASK="assembleDebug"   # gradle task used to verify the fix
MAX_RETRIES=3
CLAUDE_PROMPT_MODE="arg"     # "arg" (-p "...") | "stdin" (pipe)
CRON_INTERVAL=5              # expected run interval in minutes (used by watchdog)
```

That's it — `agent.sh` will discover it on the next run.

### Escape hatch for custom scripts

If an app has unique logic that doesn't fit `worker.sh`, set `CUSTOM_SCRIPT`:

```bash
APP_SLUG="triviaapp"
PROJECT_DIR="/Users/you/dev/triviaapp"
BUGS_REPO="itsikh/triviaapp"
CUSTOM_SCRIPT="/Users/you/dev/triviaapp/scripts/claude-autofix.sh"
CRON_INTERVAL=20
```

`agent.sh` will exec the custom script instead of `worker.sh`.

## Directory layout

```
autofix-agent/
├── agent.sh            ← dispatcher
├── worker.sh           ← per-app fix loop
├── wrapper.sh          ← cron entry point (self-healing, Mac)
├── watchdog.sh         ← health monitor (Mac)
├── install.sh          ← one-time setup (Mac cron)
├── .github/workflows/
│   └── autofix.yml     ← hourly cloud run (GitHub Actions)
├── ci/
│   ├── clone-app.sh    ← clones one app into the CI workspace
│   └── freebuff-run.sh ← drives the Freebuff TUI through tmux (fallback)
├── lib/
│   └── ai-provider.sh  ← Claude ↔ Freebuff switch (limit detection, reset time)
├── tests/              ← offline tests (bash tests/test-*.sh)
├── cloud/              ← paid-VM fallback (see docs/CLOUD.md)
│   └── gradle.properties
├── setup-cloud.sh      ← provisions a GCE VM (fallback path)
├── test-cloud-build.sh ← measures real build memory per app
├── docs/
│   └── CLOUD.md        ← cloud setup, secrets, sizing data
├── apps/               ← per-app config files
│   ├── anova.conf
│   ├── buddy.conf
│   ├── calcvault.conf
│   ├── calcvaultdesktop.conf
│   ├── callguard.conf
│   ├── cash.conf
│   ├── finnencer.conf
│   ├── medreminder.conf
│   ├── mychef.conf
│   ├── mylock.conf
│   ├── myradio.conf
│   ├── sosblocker.conf
│   ├── triviaapp.conf
│   └── wakecast.conf
├── prompts/            ← Claude prompt templates
│   └── android-default.txt
└── logs/               ← runtime logs (gitignored)
    ├── cron.log
    ├── watchdog.log
    └── wrapper_run_*.log
```

## GitHub labels

Each bugs repo needs two labels (created automatically on first run):

| Label | Meaning |
|-------|---------|
| `autofix` | Issue is approved for autonomous fixing |
| `claude-active` | Agent is currently working on this issue |

Group related issues into a single Claude task by adding the same `story:<name>` label to each.

## Configuration reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP_SLUG` | ✓ | — | Short name (used in logs) |
| `PROJECT_DIR` | ✓ | — | Absolute path to the Android project |
| `BUGS_REPO` | ✓ | — | `owner/repo` on GitHub |
| `LOCK_SLUG` | | `APP_SLUG` | Lock dir name: `/tmp/<LOCK_SLUG>-autofix.lockdir` |
| `GIT_REMOTES` | | `auto` | `auto` or space-separated remote names |
| `PROMPT_FILE` | | `android-default` | Prompt template name (no `.txt`) |
| `RELEASE_MODE` | | `skill` | `skill`, `none`, or `manual` (fix is pushed, a person releases; still shows in release-drift reports) |
| `BUILD_TASK` | | `assembleDebug` | Gradle task to verify the fix |
| `BUILD_CMD` | | — | Shell command (run in the project dir) that replaces `./gradlew $BUILD_TASK` for non-Gradle apps |
| `APPROVED_BY` | | — | Comma-separated GitHub logins. When set, an issue is only taken if its `AUTOFIX_LABEL` was added by one of them and the title/body were not edited afterwards (fails closed) |
| `BUILD_ENV_CHECK_CMD` | | — | Toolchain probe for `BUILD_CMD` apps (e.g. `node -v && go version`) |
| `PROTECTED_PATHS` | | — | Git pathspecs a fix must not touch; touching one fails the attempt |
| `MAX_RETRIES` | | `3` | Fix attempts before giving up |
| `CLAUDE_PROMPT_MODE` | | `arg` | `arg` or `stdin` |
| `CRON_INTERVAL` | | `5` | Expected minutes between runs (watchdog health check) |
| `CUSTOM_SCRIPT` | | — | If set, exec this script instead of `worker.sh` |
| `CODE_REPO` | | — | Clone URL for cloud runs (required for GitHub Actions) |
| `CODE_REPO_MIRROR` | | — | Optional second push remote, added as `mirror` |
| `ENABLED` | | `true` | `false` skips the app everywhere — local **and** cloud |
| `CLOUD_SKIP` | | — | `true` skips the app on non-Mac hosts only |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOFIX_MAX_PARALLEL` | `3` | Max concurrent workers in `agent.sh` |
| `AUTOFIX_ONLY_APP` | — | Restrict the run to a single app slug |
| `AUTOFIX_WORKSPACE` | — | If set, `PROJECT_DIR` becomes `<workspace>/<slug>` (CI) |
| `AUTOFIX_FALLBACK` | `freebuff` | `none` disables the Freebuff fallback |
| `AUTOFIX_STATE_DIR` | `~/.autofix-agent-state` | Claude reset time + provider switch log |
| `FREEBUFF_TIMEOUT_MIN` | `60` | Max minutes for one Freebuff run, wait in line included |
| `AUTOFIX_FREEBUFF_BUDGET_MIN` | `90` | Total Freebuff minutes per worker run (one attempt per issue) |
| `FREEBUFF_CONFIG_DIR` | `~/.config/manicode` | Freebuff credentials dir (absolute); or set `AUTOFIX_CODEBUFF_API_KEY` |
| `FREEBUFF_TAKEOVER` | `yes` in CI, else `no` | Press "Take over" when the account's session is in use elsewhere (ends that session) |
| `FREEBUFF_ISOLATION` | `auto` | `user` = run as the `autofix-fb` user (CI default), `same` = as you (local default) |

Override: `AUTOFIX_MAX_PARALLEL=5 ./agent.sh`

Useful flags:

```bash
./agent.sh --list-json     # print apps with unclaimed issues as JSON; run no workers
./agent.sh --max-parallel 5
```

## Freebuff fallback

When Claude reports a usage limit (weekly/session limit, `usage limit reached`,
low credit, 429), the worker records the reset time, resets the tree, and reruns
the same fix with [Freebuff](https://freebuff.com) — the free, ad-supported
Codebuff agent, driven headlessly through tmux by `ci/freebuff-run.sh`. Claude is
not called again until the reset time; then it is tried first, and a success
switches back. Every switch is logged as an `AI-PROVIDER:` line. If Freebuff is
unavailable as well (or its per-run budget is spent), the issue is left untouched
for the next run (no retry spent, no stuck label, exit 0, mailed once per block).
`/release` is deferred while Claude is blocked.

**Privacy:** Freebuff is ad-supported; its default model (Beam 1.0) is shown with
"May use data for AI training". Private app code is sent to it — only while
Claude is out of quota, with every credential but its own removed from its
environment and, in CI, as an isolated user that cannot read the runner's files
(signing files placed in the clone are moved out for the session). That
protects secrets from being *read* during the session; it is not a sandbox for
the code the agent writes, which the verification build then runs as the
runner, as it does Claude's.
Disable with `AUTOFIX_FALLBACK=none` (or, in CI, by not setting the Freebuff
secret). Details, secrets and the switch-back: [docs/CLOUD.md](docs/CLOUD.md#freebuff-fallback).
Tests: `bash tests/test-ai-fallback.sh`, `bash tests/test-worker-noai.sh` and `bash tests/test-approval-gate.sh` (also run by `.github/workflows/tests.yml` on `feature/**` pushes; no secrets).

## Logs

- `logs/cron.log` — `wrapper.sh` output (what cron sees)
- `logs/watchdog.log` — `watchdog.sh` output
- `logs/alerts.log` — alerts that triggered macOS notifications
- `logs/wrapper_run_*.log` — per-attempt output from `agent.sh`
- `<PROJECT_DIR>/.autofix-logs/` — per-app worker logs and task logs
