#!/usr/bin/env bash
# setup-cloud.sh — Provision a GCE e2-micro (Debian/Ubuntu) for autofix-agent
#
# Run once as the VM user after SSH-ing in:
#   bash setup-cloud.sh
#
# What this does:
#   1. Installs Java 17 (Eclipse Temurin), Android SDK, GitHub CLI, Node.js, Claude CLI
#   2. Clones all project repos that have GitHub HTTPS remotes
#   3. Writes ~/.gradle/gradle.properties with e2-micro-safe settings
#   4. Writes ~/.profile additions for ANDROID_HOME, JAVA_HOME, API keys
#   5. Installs crontab
#
# After running, fill in the secrets printed at the end:
#   ~/.config/autofix/secrets  (sourced by cron wrapper)

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DIR="${HOME}/dev"

log() { echo "[setup] $*"; }
die() { echo "[setup] ERROR: $*" >&2; exit 1; }

[[ "$(uname)" == "Linux" ]] || die "This script is for Linux (GCE) only"

log "=== autofix-agent cloud setup ==="
log "Agent dir: $AGENT_DIR"
log "Dev dir:   $DEV_DIR"
echo

# ── 1. System packages ────────────────────────────────────────────────────────
log "Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget unzip git python3 python3-pip \
    ca-certificates gnupg lsb-release

# ── 2. Java 17 (Eclipse Temurin) ─────────────────────────────────────────────
log "Installing Java 17 (Eclipse Temurin)..."
if ! command -v java &>/dev/null || ! java -version 2>&1 | grep -q "17\|21"; then
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/adoptium.gpg
    echo "deb https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/adoptium.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq temurin-17-jdk
fi

JAVA_HOME_VAL="$(readlink -f "$(command -v java)" | sed 's|/bin/java$||')"
log "Java home: $JAVA_HOME_VAL"

# ── 3. Android SDK ────────────────────────────────────────────────────────────
ANDROID_HOME="${HOME}/android-sdk"
CMDLINE_TOOLS_DIR="${ANDROID_HOME}/cmdline-tools/latest"

if [[ ! -d "$CMDLINE_TOOLS_DIR" ]]; then
    log "Installing Android command-line tools..."
    mkdir -p "${ANDROID_HOME}/cmdline-tools"
    CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    TMP_ZIP="$(mktemp --suffix=.zip)"
    wget -q -O "$TMP_ZIP" "$CMDLINE_URL"
    unzip -q "$TMP_ZIP" -d "${ANDROID_HOME}/cmdline-tools"
    mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "$CMDLINE_TOOLS_DIR"
    rm -f "$TMP_ZIP"
fi

export ANDROID_HOME
export PATH="${CMDLINE_TOOLS_DIR}/bin:${ANDROID_HOME}/platform-tools:$PATH"

log "Accepting Android SDK licenses..."
yes | sdkmanager --licenses >/dev/null 2>&1 || true

log "Installing Android SDK components (platforms;android-35, build-tools;35.0.0)..."
sdkmanager \
    "platforms;android-35" \
    "build-tools;35.0.0" \
    "platform-tools" \
    >/dev/null 2>&1

log "Android SDK ready at $ANDROID_HOME"

# ── 4. GitHub CLI ─────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
fi
log "gh CLI: $(gh --version | head -1)"

# ── 5. Node.js + Claude CLI ───────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
    log "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
    sudo apt-get install -y -qq nodejs
fi
log "Node: $(node --version)"

if ! command -v claude &>/dev/null; then
    log "Installing Claude CLI..."
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
fi
log "Claude CLI: $(claude --version 2>/dev/null || echo 'installed')"

# ── 6. Clone project repos ───────────────────────────────────────────────────
log "Cloning project repos into $DEV_DIR ..."
mkdir -p "$DEV_DIR"

clone_if_missing() {
    local url="$1"
    local dir="$2"
    if [[ -d "${DEV_DIR}/${dir}/.git" ]]; then
        log "  $dir: already cloned — skipping"
    else
        log "  $dir: cloning from $url ..."
        git clone "$url" "${DEV_DIR}/${dir}"
    fi
}

# Apps with GitHub HTTPS remotes (safe for cloud, no SSH needed)
clone_if_missing "https://github.com/itsikh/Anova.git"       "Anova"
clone_if_missing "https://github.com/itsikh/buddy-app.git"    "English-teacher"
clone_if_missing "https://github.com/itsikh/calc-vault.git"   "calc-vault"
clone_if_missing "https://github.com/itsikh/MedReminder.git"  "MedReminder"
clone_if_missing "https://github.com/itsikh/mylock.git"       "MyLock"
clone_if_missing "https://github.com/itsikh/CallAuditer.git"  "CallGuardEvidence"

# ── Bitbucket SSH setup (mychef + sosblocker) ─────────────────────────────────
# These repos live on Bitbucket. We generate a dedicated SSH key for this VM,
# then you add it once to your Bitbucket account.
SSH_KEY="${HOME}/.ssh/id_ed25519_bitbucket"
if [[ ! -f "$SSH_KEY" ]]; then
    log "Generating Bitbucket SSH key at $SSH_KEY ..."
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "autofix-cloud-$(hostname)"
    # Add to ssh-agent config so git uses it automatically for bitbucket.org
    cat >> "${HOME}/.ssh/config" <<SSHCONF

Host bitbucket.org
    IdentityFile ${SSH_KEY}
    StrictHostKeyChecking no
SSHCONF
    chmod 600 "${HOME}/.ssh/config"
fi

echo
echo "════════════════════════════════════════════════════════"
echo " STEP REQUIRED: Add this SSH public key to Bitbucket"
echo " Bitbucket → Personal settings → SSH keys → Add key"
echo "════════════════════════════════════════════════════════"
cat "${SSH_KEY}.pub"
echo "════════════════════════════════════════════════════════"
echo " Press ENTER after you've added the key to Bitbucket..."
read -r

# Verify SSH works before cloning
if ssh -T git@bitbucket.org 2>&1 | grep -q "logged in as"; then
    log "Bitbucket SSH auth: OK"
    clone_if_missing "git@bitbucket.org:itsik_harel/mychef.git"     "mychef"
    clone_if_missing "git@bitbucket.org:itsik_harel/sosblocker.git" "SOSBlocker"
    clone_if_missing "git@bitbucket.org:itsik_harel/triviaapp.git"  "triviaapp"
else
    log "WARNING: Bitbucket SSH auth failed — mychef, sosblocker, triviaapp NOT cloned."
    log "  Fix SSH auth, then run manually:"
    log "    git clone git@bitbucket.org:itsik_harel/mychef.git ~/dev/mychef"
    log "    git clone git@bitbucket.org:itsik_harel/sosblocker.git ~/dev/SOSBlocker"
    log "    git clone git@bitbucket.org:itsik_harel/triviaapp.git ~/dev/triviaapp"
fi

log "Repos cloned."

# ── 7. ~/.gradle/gradle.properties ───────────────────────────────────────────
log "Writing ~/.gradle/gradle.properties ..."
mkdir -p "${HOME}/.gradle"

sed "s|^# org.gradle.java.home=|org.gradle.java.home=${JAVA_HOME_VAL}|" \
    "${AGENT_DIR}/cloud/gradle.properties" \
    > "${HOME}/.gradle/gradle.properties"

log "Gradle properties written."

# ── 8. Environment setup (~/.config/autofix/secrets) ─────────────────────────
SECRETS_FILE="${HOME}/.config/autofix/secrets"
mkdir -p "$(dirname "$SECRETS_FILE")"

if [[ ! -f "$SECRETS_FILE" ]]; then
    cat > "$SECRETS_FILE" <<'EOF'
# autofix-agent secrets — fill in and chmod 600 this file
# Sourced by wrapper.sh on every cron run.

export ANTHROPIC_API_KEY="YOUR_ANTHROPIC_API_KEY_HERE"

# GitHub auth: either a token (GH_TOKEN) or run `gh auth login` interactively.
# GH_TOKEN must have: repo, read:org scopes.
export GH_TOKEN="YOUR_GITHUB_TOKEN_HERE"

# Android SDK
export ANDROID_HOME="${HOME}/android-sdk"
export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# Java
export JAVA_HOME="JAVA_HOME_PLACEHOLDER"
export PATH="${JAVA_HOME}/bin:${PATH}"
EOF
    # Fill in the JAVA_HOME we detected
    sed -i "s|JAVA_HOME_PLACEHOLDER|${JAVA_HOME_VAL}|" "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    log "Created $SECRETS_FILE — FILL IN API KEYS before starting cron."
else
    log "$SECRETS_FILE already exists — skipping."
fi

# ── 9. Patch wrapper.sh to source secrets on Linux ───────────────────────────
# wrapper.sh is the cron entry point. We need it to source the secrets file.
WRAPPER="${AGENT_DIR}/wrapper.sh"
if ! grep -q "autofix/secrets" "$WRAPPER"; then
    log "Patching wrapper.sh to source secrets on Linux..."
    # Insert source line after the shebang + set line
    sed -i '2a\\n# Source cloud secrets (Linux/GCP only)\n[[ -f "${HOME}/.config/autofix/secrets" ]] \&\& source "${HOME}/.config/autofix/secrets"' \
        "$WRAPPER"
fi

# ── 10. Install crontab ───────────────────────────────────────────────────────
log "Installing crontab..."
CRON_LINE="*/5 * * * * bash ${AGENT_DIR}/wrapper.sh >> ${AGENT_DIR}/logs/cron.log 2>&1"

if crontab -l 2>/dev/null | grep -qF "autofix-agent"; then
    log "Crontab already has autofix entry — skipping."
else
    ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
    log "Crontab installed."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo " Setup complete!"
echo "════════════════════════════════════════════════════════"
echo
echo " REQUIRED: Fill in your API keys before cron starts:"
echo "   nano ${SECRETS_FILE}"
echo
echo "   ANTHROPIC_API_KEY  — https://console.anthropic.com/keys"
echo "   GH_TOKEN           — https://github.com/settings/tokens"
echo "                        (scopes: repo, read:org)"
echo
echo " Then authenticate gh CLI interactively:"
echo "   gh auth login"
echo
echo " Verify setup:"
echo "   bash ${AGENT_DIR}/wrapper.sh"
echo "   tail -f ${AGENT_DIR}/logs/cron.log"
echo
echo " Apps running on this cloud instance:"
echo "   anova, buddy, calcvault, callguard, medreminder, mylock"
echo "   mychef, sosblocker, triviaapp  (if Bitbucket SSH succeeded above)"
echo "════════════════════════════════════════════════════════"
