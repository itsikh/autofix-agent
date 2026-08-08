# Running autofix in the cloud

Two autofix agents run against the same apps, and they are designed to coexist:

| | Where | Interval | Triggered by |
|---|---|---|---|
| **Local** | Your Mac | every 5 min | `crontab` → `wrapper.sh` → `agent.sh` |
| **Cloud** | GitHub Actions | hourly at :17 | `.github/workflows/autofix.yml` |

Both are live. Neither replaces the other.

---

## How the two avoid duplicating work

The `claude-active` GitHub label is the lock, and because it lives on GitHub it
arbitrates **across machines** — a `/tmp` lockdir never could.

1. A run claims an issue by adding `claude-active` (`worker.sh`).
2. `worker.sh` excludes `claude-active` issues when building its task list.
3. `agent.sh` excludes them during its scan too, so the cloud run does not even
   clone a repo whose only issue the Mac already claimed.
4. The label is removed when the task finishes.

Residual race: if both start within the same few seconds, both may read the
issue list before either applies the label. The window is seconds; `worker.sh`
rebases and pushes with `--force-with-lease`, so the git-level outcome stays
safe. Duplicate effort is possible but rare.

If the Mac is asleep, the hourly cloud run simply picks the work up.

---

## Why not a GCP free-tier VM

The original plan (`setup-cloud.sh`, `cloud/gradle.properties`) targeted a GCE
`e2-micro`, which the [Always Free tier](https://docs.cloud.google.com/free/docs/free-cloud-features)
gives as **1 GB RAM, 0.25 vCPU baseline, 30 GB standard disk**, in
`us-west1`/`us-central1`/`us-east1` only.

It does not fit. `test-cloud-build.sh` measured actual peak resident memory of
the whole build process tree (clean `assembleDebug`, `-Xmx700m`):

| App | Tree peak | Largest single process |
|---|---|---|
| callguard | 4611 MB | 4384 MB |
| finnencer | 3252 MB | 3081 MB |
| sosblocker | 3001 MB | 2909 MB |
| medreminder | 2825 MB | 2661 MB |

Even the smallest app needs ~3 GB — roughly **3× an e2-micro**, at any heap
setting. CPU is worse: builds taking 40–95 s on Apple silicon would take far
longer on 0.25 vCPU, and sustained hourly load exhausts burst credits.

> **An earlier report claimed the free tier was viable. It was wrong.**
> The old probe used `/usr/bin/time -l`, which only sees direct waited-for
> children — it measured the `gradlew` wrapper shell (113 MB, 1.42 s CPU) and
> never saw the JVM. Its summary also picked a VM tier from the `-Xmx` value
> rather than from measured memory. Both bugs are fixed; the probe now samples
> the whole process tree every 0.5 s.

**Cloud Functions / Cloud Run are the wrong shape** regardless of memory: no
persistent Gradle cache (every build cold), a ~3 GB Android SDK image to pull,
and this is a long-lived agent loop rather than a request handler.

`setup-cloud.sh` and `cloud/gradle.properties` are kept as a **paid-VM fallback**
— on an `e2-medium` (4 GB, ~$13/mo) they work as written.

---

## Why GitHub Actions is free here

Actions minutes are billed to the repo that **hosts the workflow**, not the repos
it checks out. `itsikh/autofix-agent` is **public**, and public repos on standard
runners are [free and unlimited](https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions).
So the hourly run costs nothing even while it fixes your *private* app repos.

Public repos also get the larger runner: **4 vCPU / 16 GB**, versus 2 vCPU / 8 GB
for private. Android SDK is preinstalled at `/usr/local/lib/android/sdk`.

> ⚠️ **If `autofix-agent` is ever made private, this stops being free.** The Free
> plan allows 2,000 minutes/month for private repos, which hourly polling alone
> would largely consume.

---

## Workflow shape

```
scan  (~1 min, no clones)
  └── agent.sh --list-json → JSON array of app slugs with unclaimed issues
        │
        └── fix  (matrix, one job per app, max-parallel 1)
              ├── clone only that app          ci/clone-app.sh
              ├── restore Gradle cache
              └── worker.sh apps/<slug>.conf
```

An idle hour costs about one minute because `scan` clones nothing. The `fix`
job only materialises for apps that actually have work.

---

## Secrets

All credentials live in **Settings → Secrets and variables → Actions**. Nothing
sensitive is committed to this repo.

| Secret | Required | Purpose |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | yes* | Claude auth via your **subscription**. Generate with `claude setup-token`. |
| `ANTHROPIC_API_KEY` | alt* | Use *instead* of the above to bill per-token through the API. |
| `APP_REPO_TOKEN` | yes | Fine-grained PAT for the app repos: **Contents** read+write, **Issues** read+write. |
| `BITBUCKET_SSH_KEY` | yes | Private ed25519 key for the Bitbucket-only apps (`calcvault`, `mychef`, `sosblocker`). |

\* Set one or the other. `CLAUDE_CODE_OAUTH_TOKEN` uses the subscription you
already pay for; `ANTHROPIC_API_KEY` adds metered API charges.

### How they are kept safe

- **No fork can reach them.** Triggers are limited to `schedule` and
  `workflow_dispatch`. There is deliberately no `pull_request` trigger.
- **Never interpolated into `run:` bodies.** Secrets are passed via step-level
  `env:` so they cannot appear in a rendered command line.
- **Never written to `.git/config`.** The git credential helper reads
  `APP_REPO_TOKEN` from the environment at push time rather than embedding a
  token in a remote URL.
- **`persist-credentials: false`** on checkout, so no token is left behind.
- **Least privilege:** the workflow's `GITHUB_TOKEN` is `contents: read`.
- **SSH key** is written under `umask 077`, `chmod 600`, with `bitbucket.org`
  pinned via `ssh-keyscan`.

### ⚠️ Public logs

This repo is public, so **Actions logs are world-readable** — and worker output
contains source, diffs and issue text from your *private* app repos. The
workflow therefore writes full output to a file and echoes only dispatcher-level
status lines.

Run with `verbose_logs: true` (workflow_dispatch) to print everything. Only do
that when debugging an app whose contents you are comfortable publishing.

---

## Generating the secrets

```bash
# 1. Claude subscription token
claude setup-token          # paste result into CLAUDE_CODE_OAUTH_TOKEN

# 2. Bitbucket key — reuse the one setup-cloud.sh makes, or:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_bitbucket -N "" -C "autofix-ci"
cat ~/.ssh/id_ed25519_bitbucket        # → BITBUCKET_SSH_KEY (private key)
cat ~/.ssh/id_ed25519_bitbucket.pub    # → add to Bitbucket → Personal settings → SSH keys
```

For `APP_REPO_TOKEN`: github.com/settings/personal-access-tokens → fine-grained
→ select the app repos → Contents: read+write, Issues: read+write.

Add each with:

```bash
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo itsikh/autofix-agent
gh secret set APP_REPO_TOKEN          --repo itsikh/autofix-agent
gh secret set BITBUCKET_SSH_KEY       --repo itsikh/autofix-agent < ~/.ssh/id_ed25519_bitbucket
```

---

## Registering an app for cloud runs

On top of the normal `.conf` keys, the cloud run needs to know where to clone
from, because a runner starts empty:

```bash
CODE_REPO="https://github.com/itsikh/MyApp.git"              # cloned as "origin"
CODE_REPO_MIRROR="git@bitbucket.org:itsik_harel/myapp.git"   # optional 2nd remote
```

`CODE_REPO_MIRROR` is added as a remote named `mirror`, so `GIT_REMOTES="auto"`
pushes to both — matching what the Mac already does with its dual remotes.

Prefer the **GitHub** URL for `CODE_REPO` where a mirror exists: it authenticates
with `APP_REPO_TOKEN` and needs no SSH key.

| Key | Effect |
|---|---|
| `CODE_REPO` | Clone URL for CI. Required for cloud runs. |
| `CODE_REPO_MIRROR` | Optional second push target. |
| `ENABLED="false"` | Skip this app everywhere — local *and* cloud. |
| `CLOUD_SKIP="true"` | Skip on non-Mac hosts only. |

### Currently registered

| App | CI clone source | Mirror |
|---|---|---|
| anova | GitHub | Bitbucket |
| buddy | GitHub | Bitbucket |
| callguard | GitHub | Bitbucket |
| finnencer | GitHub | Bitbucket |
| mylock | GitHub | Bitbucket |
| medreminder | GitHub | — |
| calcvault | Bitbucket (SSH) | — |
| mychef | Bitbucket (SSH) | — |
| sosblocker | Bitbucket (SSH) | — |
| ~~triviaapp~~ | **disabled** | — |

**triviaapp is disabled.** Its `BUGS_REPO="itsikh/triviaapp"` does not exist on
GitHub, so every issue lookup failed silently — on the Mac as well as in CI. Its
code is on Bitbucket but nothing hosts its issues. To re-enable: create a GitHub
repo for its issues, set `BUGS_REPO` and `CODE_REPO`, and remove `ENABLED="false"`.

---

## Operating notes

- **Scheduled runs drift.** GitHub delays `schedule:` triggers under load, often
  10–30 minutes. Fine hourly; do not expect punctuality.
- **Schedules auto-disable** after 60 days without repo activity.
- **`concurrency: autofix`** prevents two cloud runs overlapping.
  `cancel-in-progress` is off on purpose: cancelling mid-fix would strand an
  issue labelled `claude-active`.
- **Manual run:** Actions → autofix → Run workflow. The `app` input restricts it
  to a single slug.
- **`watchdog.sh` and `wrapper.sh` are Mac-only.** Actions provides its own retry
  and failure surfacing.

## Re-measuring build memory

```bash
./test-cloud-build.sh                 # all apps, heaps 512→2048
./test-cloud-build.sh --quick         # 700m and 1500m only
./test-cloud-build.sh --app mylock
./test-cloud-build.sh --no-clean      # skip clean (measures little — see below)
```

Clean builds are the default: an incremental build reports "N up-to-date",
compiles nothing, and measures no memory. It also matches the cold state of a
fresh cloud clone. **Side effect: wipes `build/` in the probed projects.**

Reports land in `logs/cloud-build-test/`.
