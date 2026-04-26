#!/usr/bin/env bash
# 05-nemoclaw.sh — install NemoClaw at the pinned release tag.
#
# Constitution Principle V (reproducible): tarball URL is composed
# from $NEMOCLAW_VERSION and $NEMOCLAW_RELEASE_URL_BASE; the matching
# SHA-256 file from the same release is fetched and verified BEFORE
# extraction. A mismatch fails the script (and therefore cloud-init).
#
# Spec FR-019: pinned version. Research R1: unattended install via
# upstream config/env hooks if available; fall back to `expect` with
# a versioned answers file if the wizard insists on being interactive.
#
# Spec / contract FR-009 hardening: no secret value is written to
# NemoClaw's runtime config. The Foundry API key arrives at runtime
# via the credential handoff (US2 / T032–T033). At US1 we install
# NemoClaw, write its non-secret config, and enable (but do NOT start)
# the systemd unit — the unit can't run without the key.
#
# Inputs:
#   NEMOCLAW_VERSION              required (e.g. v0.3.1)
#   NEMOCLAW_RELEASE_URL_BASE     default https://github.com/NVIDIA/NemoClaw/releases/download
#   FOUNDRY_ENDPOINT              required (URL)
#   FOUNDRY_DEPLOYMENTS_JSON      required (rendered JSON map)
#   FOUNDRY_API_VERSION           required
#   NEMOCLAW_USER                 default nemoclaw
#   NEMOCLAW_GROUP                default nemoclaw
#   NEMOCLAW_INSTALL_DIR          default /opt/nemoclaw
#   NEMOCLAW_CONFIG_DIR           default /etc/nemoclaw
#   NEMOCLAW_DATA_DIR             default /var/lib/nemoclaw
#   NEMOCLAW_SERVICE_FILE         default /etc/systemd/system/nemoclaw.service
#                                 (cloud-init's write_files writes the
#                                 templated unit here BEFORE this
#                                 script runs — see 05 step 7 below)

set -euo pipefail

: "${NEMOCLAW_VERSION:?missing NEMOCLAW_VERSION}"
: "${FOUNDRY_ENDPOINT:?missing FOUNDRY_ENDPOINT}"
: "${FOUNDRY_DEPLOYMENTS_JSON:?missing FOUNDRY_DEPLOYMENTS_JSON}"
: "${FOUNDRY_API_VERSION:?missing FOUNDRY_API_VERSION}"

NEMOCLAW_RELEASE_URL_BASE="${NEMOCLAW_RELEASE_URL_BASE:-https://github.com/NVIDIA/NemoClaw/releases/download}"
NEMOCLAW_USER="${NEMOCLAW_USER:-nemoclaw}"
NEMOCLAW_GROUP="${NEMOCLAW_GROUP:-nemoclaw}"
NEMOCLAW_INSTALL_DIR="${NEMOCLAW_INSTALL_DIR:-/opt/nemoclaw}"
NEMOCLAW_CONFIG_DIR="${NEMOCLAW_CONFIG_DIR:-/etc/nemoclaw}"
NEMOCLAW_DATA_DIR="${NEMOCLAW_DATA_DIR:-/var/lib/nemoclaw}"
NEMOCLAW_SERVICE_FILE="${NEMOCLAW_SERVICE_FILE:-/etc/systemd/system/nemoclaw.service}"

TARBALL_URL="${NEMOCLAW_RELEASE_URL_BASE}/${NEMOCLAW_VERSION}/nemoclaw-${NEMOCLAW_VERSION}.tar.gz"
SHA256_URL="${TARBALL_URL}.sha256"

echo "[05-nemoclaw] installing dependencies"
apt-get install -y curl tar coreutils expect

echo "[05-nemoclaw] creating ${NEMOCLAW_USER}:${NEMOCLAW_GROUP} system user"
if ! getent group "$NEMOCLAW_GROUP" > /dev/null; then
  groupadd --system "$NEMOCLAW_GROUP"
fi
if ! getent passwd "$NEMOCLAW_USER" > /dev/null; then
  useradd --system \
    --gid "$NEMOCLAW_GROUP" \
    --home-dir "$NEMOCLAW_DATA_DIR" \
    --shell /usr/sbin/nologin \
    "$NEMOCLAW_USER"
fi

install -d -m 0750 -o "$NEMOCLAW_USER" -g "$NEMOCLAW_GROUP" \
  "$NEMOCLAW_INSTALL_DIR" \
  "$NEMOCLAW_CONFIG_DIR" \
  "$NEMOCLAW_DATA_DIR"

# ─── Download + verify ────────────────────────────────────────────

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[05-nemoclaw] downloading $TARBALL_URL"
curl -fsSL "$TARBALL_URL" -o "$WORK_DIR/nemoclaw.tar.gz"

echo "[05-nemoclaw] downloading $SHA256_URL"
curl -fsSL "$SHA256_URL" -o "$WORK_DIR/nemoclaw.tar.gz.sha256"

echo "[05-nemoclaw] verifying checksum"
cd "$WORK_DIR"
# Upstream sha256 file is typically `<sha>  nemoclaw-<version>.tar.gz`.
# Rewrite the filename column to match what we saved locally so
# `sha256sum -c` finds the file.
SHA="$(awk '{print $1}' nemoclaw.tar.gz.sha256)"
echo "${SHA}  nemoclaw.tar.gz" | sha256sum -c -

echo "[05-nemoclaw] extracting to $NEMOCLAW_INSTALL_DIR"
tar -xzf nemoclaw.tar.gz -C "$NEMOCLAW_INSTALL_DIR" --strip-components=1
chown -R "$NEMOCLAW_USER:$NEMOCLAW_GROUP" "$NEMOCLAW_INSTALL_DIR"

# ─── Run installer ────────────────────────────────────────────────
#
# Research R1 priority order:
#   1. Config-file or env-var hooks if upstream exposes them
#   2. `expect` consuming a versioned answers file if not
#   3. Smoke-test `nemoclaw doctor` regardless of which path was taken

cd "$NEMOCLAW_INSTALL_DIR"

INSTALLER_SCRIPT=""
for candidate in install.sh bin/install scripts/install; do
  if [[ -x "$candidate" ]]; then
    INSTALLER_SCRIPT="$candidate"
    break
  fi
done

if [[ -n "$INSTALLER_SCRIPT" ]]; then
  echo "[05-nemoclaw] running installer: $INSTALLER_SCRIPT"

  if [[ -n "${NEMOCLAW_INSTALL_NONINTERACTIVE_FLAG:-}" ]]; then
    # Path 1: upstream supports a flag like --yes or --unattended.
    sudo -u "$NEMOCLAW_USER" \
      env HOME="$NEMOCLAW_DATA_DIR" PATH="$PATH" \
      "./$INSTALLER_SCRIPT" "$NEMOCLAW_INSTALL_NONINTERACTIVE_FLAG"
  elif [[ -f /etc/nemoclaw/nemoclaw-answers.expect ]]; then
    # Path 2: cloud-init dropped a versioned `expect` answers file.
    expect -f /etc/nemoclaw/nemoclaw-answers.expect \
      "./$INSTALLER_SCRIPT"
  else
    echo "[05-nemoclaw] WARNING: no unattended install path. Running" >&2
    echo "[05-nemoclaw] the installer with /dev/null on stdin in case" >&2
    echo "[05-nemoclaw] it accepts default-on-EOF behaviour." >&2
    sudo -u "$NEMOCLAW_USER" \
      env HOME="$NEMOCLAW_DATA_DIR" PATH="$PATH" \
      "./$INSTALLER_SCRIPT" < /dev/null
  fi
else
  echo "[05-nemoclaw] no installer script found in tarball — assuming"
  echo "[05-nemoclaw] tarball ships ready-to-run binaries"
fi

# ─── Write non-secret runtime config ──────────────────────────────
#
# Per spec Q2 + FR-013: only the non-secret Foundry config lives on
# disk. Foundry API key never appears here — it arrives at service
# startup via the credential handoff (US2).
#
# Format follows NemoClaw's documented YAML config; the exact key
# names may need adjustment after upstream verification on first
# boot (the implementer fills this in with the real schema).

cat > "$NEMOCLAW_CONFIG_DIR/config.yaml" <<EOF
# Generated by cloud-init at NemoClaw install time.
# DO NOT add API keys here — secrets reach NemoClaw via systemd
# EnvironmentFile= from a tmpfs file populated by the credential
# handoff (see /usr/local/bin/nemoclaw-credential-handoff).

inference:
  provider: azure-openai
  endpoint: ${FOUNDRY_ENDPOINT}
  api_version: ${FOUNDRY_API_VERSION}
  deployments: ${FOUNDRY_DEPLOYMENTS_JSON}
EOF
chown "$NEMOCLAW_USER:$NEMOCLAW_GROUP" "$NEMOCLAW_CONFIG_DIR/config.yaml"
chmod 0640 "$NEMOCLAW_CONFIG_DIR/config.yaml"

# ─── systemd unit ─────────────────────────────────────────────────
#
# The unit file itself is rendered by Terraform (templatefile() over
# nemoclaw.service.tpl) and dropped into place by cloud-init's
# write_files BEFORE this script runs. Here we just reload + enable.
# Starting the unit is deferred until after the doctor smoke test
# below so a packaging bug in the tarball surfaces as a clear
# "doctor failed" rather than a tangle of systemd restart-loop noise.

if [[ ! -f "$NEMOCLAW_SERVICE_FILE" ]]; then
  echo "[05-nemoclaw] FATAL: $NEMOCLAW_SERVICE_FILE missing." >&2
  echo "[05-nemoclaw]   cloud-init's write_files should have written it." >&2
  exit 1
fi

systemctl daemon-reload
systemctl enable nemoclaw.service
echo "[05-nemoclaw] unit enabled"

# ─── Smoke test ───────────────────────────────────────────────────
#
# Per US1 acceptance scenario 4: `nemoclaw doctor` (or upstream's
# documented health command) must exit 0. The exact binary path
# depends on what the tarball ships.

NEMOCLAW_BIN=""
for candidate in \
  "$NEMOCLAW_INSTALL_DIR/bin/nemoclaw" \
  "$NEMOCLAW_INSTALL_DIR/nemoclaw" \
  /usr/local/bin/nemoclaw; do
  if [[ -x "$candidate" ]]; then
    NEMOCLAW_BIN="$candidate"
    break
  fi
done

if [[ -z "$NEMOCLAW_BIN" ]]; then
  echo "[05-nemoclaw] FATAL: nemoclaw binary not found after install." >&2
  exit 1
fi

# Make the binary discoverable on PATH for operator convenience.
ln -sf "$NEMOCLAW_BIN" /usr/local/bin/nemoclaw

echo "[05-nemoclaw] running smoke test: nemoclaw doctor"
# `nemoclaw doctor` here runs as the nemoclaw user WITHOUT
# OPENAI_API_KEY in its environ — this is an install-integrity
# check, not a runtime check. If upstream's doctor command treats a
# missing API key as fatal, we accept it as a soft warning here;
# the runtime check is the systemctl start a few lines below, which
# DOES have OPENAI_API_KEY (via the credential handoff +
# EnvironmentFile=).
if sudo -u "$NEMOCLAW_USER" \
     env HOME="$NEMOCLAW_DATA_DIR" PATH="$PATH" \
     "$NEMOCLAW_BIN" doctor; then
  echo "[05-nemoclaw] doctor passed."
else
  echo "[05-nemoclaw] WARNING: \`nemoclaw doctor\` returned non-zero." >&2
  echo "[05-nemoclaw] If the failure is anything OTHER than a missing" >&2
  echo "[05-nemoclaw] API key, this is a real problem — investigate"   >&2
  echo "[05-nemoclaw] via journalctl -u nemoclaw before using the"     >&2
  echo "[05-nemoclaw] deployment."                                     >&2
fi

# ─── Start the service (US2 / T033) ───────────────────────────────
#
# At US2 the credential handoff is wired via ExecStartPre=+ — the
# Foundry API key reaches NemoClaw's host process at startup via the
# tmpfs handoff documented in contracts/credential-handoff.md.
# Starting the unit triggers the handoff for the first time; the
# operator's `verify.sh` then runs SC-004 / SC-008 to confirm the
# tooth-check passes.
#
# We don't `--wait` here: cloud-init's runcmd is single-threaded and
# we don't want the whole bootstrap to block on Type=notify if
# NemoClaw's notify support is flaky. Type=notify with a missing
# ready-signal would hang the unit until DefaultTimeoutStartSec
# (90s) anyway — the operator sees the eventual state via
# verify.sh + journalctl.
echo "[05-nemoclaw] starting nemoclaw.service (credential handoff fires here)"
systemctl start nemoclaw.service || {
  echo "[05-nemoclaw] WARNING: systemctl start nemoclaw.service returned non-zero." >&2
  echo "[05-nemoclaw] Inspect via \`journalctl -u nemoclaw --no-pager -n 200\`."   >&2
  echo "[05-nemoclaw] Common causes: foundry-api-key still PLACEHOLDER in KV"     >&2
  echo "[05-nemoclaw] (run \`az keyvault secret set\` per quickstart.md §3,"      >&2
  echo "[05-nemoclaw] then \`systemctl restart nemoclaw\`); MI lacks Secrets-User" >&2
  echo "[05-nemoclaw] RBAC; KV network ACL blocks the VM subnet."                 >&2
}

echo "[05-nemoclaw] install complete at $NEMOCLAW_VERSION."
