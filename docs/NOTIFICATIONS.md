# Notifications — knowing what the agent did without watching it

The agent is designed to need no supervision, which is exactly what makes it
hard to trust: a fixed bug and a silently broken build look identical from the
outside. This is how it reports itself.

## The rule that shapes everything here

**Email is attached to the two places that only exist when something happened.**

- The cloud `fix` job is gated on `if: needs.scan.outputs.count != '0'`.
- Locally, `agent.sh` logs `no open issues — skipping` and exits before
  launching a worker.
- `watchdog.sh` calls `notify_user` only when its alert array is non-empty.

So there is no "did anything happen?" test anywhere in the mail path, and no
idle-hour mail. The local cron runs every 5 minutes across 9 apps and the cloud
runs hourly; hooking notification upstream of those gates — to the cron wrapper
or the hourly `scan` job — is what would produce a mailbox full of *nothing
happened*. Don't.

## What you get an email about

One digest per run that did something, subject-lined with the verdict so the
inbox is scannable without opening anything:

```
[autofix] mylock: 1 fixed, released
[autofix] mylock: 1 fixed, NOT released
[autofix] anova: FAILED (exit 1)
[autofix] triviaapp: 1 fixed, FAILED, released
[autofix] mylock: drift released
[autofix] watchdog: Autofix Watchdog — 3 issues
```

The verdict is built **additively**, not by first match: one run handles several
issues and can fix one while failing another, and a subject reporting only the
fix would bury the failure.

The body is the run's event lines, extracted by `ci/status-lines.sh`:

| Event | Worker line |
|---|---|
| ticket picked | `Processing task: #N …` |
| fix committed | `Fix committed for #N` |
| ticket handled | `Closed issue #N` |
| first failure | `Labelled #N 'autofix-stuck'` |
| gave up | `ERROR: All N attempts failed.` |
| build env fault | `ERROR: Build environment …` |
| version shipped | `Released vX (was vY)` |
| fixed, not shipped | `ERROR: UNRELEASED …` / `ERROR: Release FAILED …` |

That regex lives in one file on purpose. It feeds both the public job log and
the email, so an event added to `worker.sh` shows up in both places or neither.
These are status lines only — no diffs, no file contents — which is what makes
them safe in a public repo's job log. `ERROR:` is included deliberately: a
hidden failure is worse than the little context an error message reveals.

## Setup

### Cloud runs

Add three repo secrets (**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `AUTOFIX_MAIL_TO` | where to send |
| `AUTOFIX_MAIL_USER` | your Gmail address |
| `AUTOFIX_MAIL_PASS` | a Gmail **app password** |

Get the app password at <https://myaccount.google.com/apppasswords> (requires
2FA). **Never put your real account password here** — an app password is
revocable and scoped to sending.

Leave them unset and nothing breaks: `ci/notify-email.sh` warns and exits 0.

### Local runs (the Mac)

`/usr/bin/mail` exists here but `/etc/postfix/main.cf` has no `relayhost` and no
SASL, so anything sent through it queues locally and never reaches Gmail. The
sender talks SMTP directly instead, so no MTA configuration is needed.

cron has almost no environment, so put the credentials in a file:

```sh
cat > ~/.autofix-mail.env <<'EOF'
AUTOFIX_MAIL_TO=you@example.com
AUTOFIX_MAIL_USER=you@gmail.com
AUTOFIX_MAIL_PASS=abcd efgh ijkl mnop
EOF
chmod 600 ~/.autofix-mail.env
```

It lives in `$HOME`, not the repo. `.gitignore` also covers the filename in
case a copy lands here.

Verify without waiting for a run:

```sh
echo "hello from autofix" | bash ci/notify-email.sh "[autofix] test"
```

### Release-only signal, no code

For "a new version shipped" and nothing else, subscribe an Atom-to-email service
(Blogtrottr, Feedrabbit) to each app's releases feed:

```
https://github.com/<owner>/<repo>/releases.atom
```

This is worth doing regardless of the above, because it is the one signal that
reaches you as a *user* of the apps rather than as their maintainer — and it is
immune to the problem in the next section.

## The one gap, and what closes it

If the hourly `scan` job itself fails — expired token, GitHub API down — `fix`
never runs, so no digest is sent. Nothing was picked up, but you would also not
hear that the agent is blind. Two things cover it: GitHub's own Actions
failure mail (about the run, not an issue, so it does arrive), and the Mac
watchdog, which checks for failed cloud runs and alerts through the same email
path. A quiet hour with a backlog is covered separately — `drift-scan` runs even
when `fix` is skipped, and `drift-release` emails when it publishes.

## Why GitHub's own notifications don't cover this

**GitHub never emails you about your own actions**, and the agent authenticates
as you via `APP_REPO_TOKEN`. That is why mylock #15's timeline reads
`commented itsikh` / `closed itsikh`. Watching the app repos therefore yields
nothing for tickets being picked, labelled, commented, or closed. Only Actions
*failure* mail arrives, because that is about the run, not an issue event.

The fix, if you ever want per-event GitHub-native mail with no code: create a
machine account, give it the app-repo access, and put **its** PAT in
`APP_REPO_TOKEN`. Then every agent action is somebody else's action and you get
notified natively by watching the repos. It also repairs the audit trail — right
now an agent close is indistinguishable from one you did by hand. It is the only
option here that needs real setup, which is why it isn't the default.

## Privacy

Digest bodies carry status lines from private app repos. That is fine for your
own inbox; don't route these mails into a shared or public destination.
