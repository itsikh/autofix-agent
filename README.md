# autofix-agent

Unified autonomous bug-fixing agent for Android apps. A single codebase replaces all per-app autofix scripts — new apps register by adding a `.conf` file.

## How it works

```
cron (every 5 min)
  └── wrapper.sh         ← meta-wrapper with self-healing
        └── agent.sh     ← dispatcher: checks all apps for open issues
              ├── worker.sh apps/mychef.conf     ┐
              ├── worker.sh apps/mylock.conf      ├─ parallel (max 3)
              └── worker.sh apps/medreminder.conf ┘

cron (every 30 min)
  └── watchdog.sh        ← health monitor & macOS notifier
```

1. **`agent.sh`** reads every `apps/*.conf` file, quick-checks GitHub for open `autofix`-labelled issues, then runs `worker.sh` for each app that has open issues — up to `MAX_PARALLEL` (default 3) at once.

2. **`worker.sh`** is the core fix loop (based on [MyLock's Gen3 autofix.sh](https://github.com/itsikh/mylock)):
   - Acquires a per-app file lock
   - Syncs git state (fetch, rebase, push)
   - Groups issues by `story:*` label
   - For each task: prompts Claude CLI to fix, verifies the build, commits, closes the issue on GitHub
   - After all tasks: triggers `/release`

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
RELEASE_MODE="skill"         # "skill" (call /release) | "none"
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
├── wrapper.sh          ← cron entry point (self-healing)
├── watchdog.sh         ← health monitor
├── install.sh          ← one-time setup
├── apps/               ← per-app config files
│   ├── mychef.conf
│   ├── mylock.conf
│   ├── medreminder.conf
│   ├── anova.conf
│   ├── callguard.conf
│   ├── sosblocker.conf
│   └── triviaapp.conf
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
| `RELEASE_MODE` | | `skill` | `skill` or `none` |
| `BUILD_TASK` | | `assembleDebug` | Gradle task to verify the fix |
| `MAX_RETRIES` | | `3` | Fix attempts before giving up |
| `CLAUDE_PROMPT_MODE` | | `arg` | `arg` or `stdin` |
| `CRON_INTERVAL` | | `5` | Expected minutes between runs (watchdog health check) |
| `CUSTOM_SCRIPT` | | — | If set, exec this script instead of `worker.sh` |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTOFIX_MAX_PARALLEL` | `3` | Max concurrent workers in `agent.sh` |

Override: `AUTOFIX_MAX_PARALLEL=5 ./agent.sh`

## Logs

- `logs/cron.log` — `wrapper.sh` output (what cron sees)
- `logs/watchdog.log` — `watchdog.sh` output
- `logs/alerts.log` — alerts that triggered macOS notifications
- `logs/wrapper_run_*.log` — per-attempt output from `agent.sh`
- `<PROJECT_DIR>/.autofix-logs/` — per-app worker logs and task logs
