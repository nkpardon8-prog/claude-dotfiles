#!/usr/bin/env bash
# install.sh — One-time, idempotent installer for the macmini-server LaunchAgent.
#
# TWO MODES:
#   userspace (default, NO SUDO) — uses Homebrew formula `tailscale` + tailscaled
#                                  --tun=userspace-networking, installs binaries
#                                  to ~/.local/bin/. Userspace tailscaled forwards
#                                  inbound tailnet traffic to localhost listeners,
#                                  so the server still becomes reachable on the
#                                  tailnet IP. This is the empirically validated
#                                  no-sudo happy path.
#   cask (legacy) — uses /Applications/Tailscale.app (the system extension cask),
#                   installs binaries to /usr/local/bin/ via sudo. Pass --mode=cask.
#
# Run this ON the Mac mini (NOT over SSH-as-different-user). It will:
#   - detect or set up Tailscale (formula preferred, cask if --mode=cask)
#   - generate a server bearer token (preserved across re-runs)
#   - install macmini-server and macmini-client (location depends on mode)
#   - render and bootstrap the per-user LaunchAgent
#   - configure power management (sudo, only in --mode=cask or with --pmset)
#   - probe Screen Recording permission via screencapture
#   - smoke-test the server's /health endpoint
#   - print a credentials.md block ready to paste
#
# Flags:
#   --mode=userspace          Default. No sudo. ~/.local/bin install paths.
#   --mode=cask               Legacy. /usr/local/bin install paths, requires sudo.
#   --rotate-token            Replace the existing bearer token. Existing clients
#                             stop working until they pick up the new value.
#   --reinstall               Force re-render of plist and re-bootstrap even if
#                             everything looks current.
#   --uninstall               Delegate to uninstall.sh (no --purge).
#   --skip-pmset              Don't run pmset (useful for laptops/test rigs).
#   --pmset                   Force pmset attempt even in userspace mode.
#   --skip-screencap-probe    Don't probe Screen Recording permission.
#   --print-token             DUMP THE CURRENT TOKEN VALUE TO STDOUT (one-time,
#                             intentional, for entering into 1Password). The token
#                             is otherwise never printed; only its sha256 fingerprint
#                             is shown. Use this once after first install, copy the
#                             value into op://<VAULT>/Mac mini CRD/Server Token, and
#                             never run this flag again.
#   --help                    Show this help.
#
# Idempotency: every step is a no-op when the desired state already matches.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

LABEL="com.macmini-skill.server"
PLIST_TEMPLATE="${SCRIPT_DIR}/com.macmini-skill.server.plist"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_PATH="${HOME}/Library/Logs/macmini-server.log"
CONFIG_DIR="${HOME}/.config/macmini-server"
TOKEN_PATH="${CONFIG_DIR}/token"

# Defaults overridden after MODE is parsed.
SERVER_DEST=""
CLIENT_DEST=""

PROBE_PNG="/tmp/__macmini-perm-probe.png"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

MODE="userspace"
ROTATE_TOKEN=0
REINSTALL=0
SKIP_PMSET=0
FORCE_PMSET=0
SKIP_SCREENCAP_PROBE=0
PRINT_TOKEN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=userspace)       MODE="userspace"; shift ;;
        --mode=cask)            MODE="cask"; shift ;;
        --rotate-token)         ROTATE_TOKEN=1; shift ;;
        --reinstall)            REINSTALL=1; shift ;;
        --uninstall)
            exec bash "${SCRIPT_DIR}/uninstall.sh"
            ;;
        --skip-pmset)           SKIP_PMSET=1; shift ;;
        --pmset)                FORCE_PMSET=1; shift ;;
        --skip-screencap-probe) SKIP_SCREENCAP_PROBE=1; shift ;;
        --print-token)          PRINT_TOKEN=1; shift ;;
        -h|--help)
            sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "See --help." >&2
            exit 2
            ;;
    esac
done

# Mode-dependent defaults.
if [[ "$MODE" == "userspace" ]]; then
    SERVER_DEST="${HOME}/.local/bin/macmini-server"
    CLIENT_DEST="${HOME}/.local/bin/macmini-client"
    # In userspace mode, pmset (sudo) is opt-in only.
    if [[ $FORCE_PMSET -eq 0 ]]; then
        SKIP_PMSET=1
    fi
else
    SERVER_DEST="/usr/local/bin/macmini-server"
    CLIENT_DEST="/usr/local/bin/macmini-client"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err()  { echo "ERROR: $*" >&2; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "==>    $*"; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "required command not found: $1"
        exit 2
    fi
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

token_fingerprint() {
    # First 8 hex chars of sha256(token contents). Never prints the token.
    /usr/bin/shasum -a 256 "$1" | awk '{print substr($1,1,8)}'
}

# ---------------------------------------------------------------------------
# --print-token: short-circuit — read existing token and dump.
# ---------------------------------------------------------------------------

if [[ $PRINT_TOKEN -eq 1 ]]; then
    if [[ ! -f "$TOKEN_PATH" ]]; then
        err "no token at $TOKEN_PATH. Run install.sh first (without --print-token)."
        exit 2
    fi
    cat "$TOKEN_PATH"
    echo
    echo "(Token dumped above. Paste into op://<VAULT>/Mac mini CRD/Server Token then" >&2
    echo " forget it. The token's fingerprint is $(token_fingerprint "$TOKEN_PATH").)" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 0: GUI session check.
# A LaunchAgent bootstrapped into gui/<uid> requires an active Aqua session.
# Catch SSH-as-different-user installs early.
# ---------------------------------------------------------------------------

if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    err "Run install.sh from a logged-in GUI session, not over SSH-as-different-user."
    err "Sit at the Mac mini, log in to the desktop, open Terminal, re-run this script."
    exit 2
fi

# ---------------------------------------------------------------------------
# Step a: macOS + arch detection.
# ---------------------------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "this installer only runs on macOS (uname -s=$(uname -s))."
    exit 2
fi

case "$(uname -m)" in
    arm64)   ARCH="arm64" ;;
    x86_64)  ARCH="amd64" ;;
    *)       err "unsupported arch: $(uname -m)"; exit 2 ;;
esac
info "macOS / ${ARCH}"

require_cmd openssl
require_cmd curl
require_cmd sed
require_cmd launchctl
require_cmd jq

# ---------------------------------------------------------------------------
# Step b: Tailscale setup. Userspace mode preferred (no sudo).
# ---------------------------------------------------------------------------

TS_BIN=""
TS_SOCKET=""

try_install_userspace_tailscale() {
    # Returns 0 if userspace tailscaled is up and tailscale CLI works against it.
    local brew_bin tailscale_bin tailscaled_bin
    brew_bin="$(command -v brew 2>/dev/null || true)"
    if [[ -z "$brew_bin" ]]; then
        warn "Homebrew not found — userspace mode requires brew. Falling back to cask discovery."
        return 1
    fi

    # Probe formula install state.
    if ! brew list tailscale >/dev/null 2>&1; then
        info "installing Homebrew formula 'tailscale' (no sudo)"
        if ! brew install tailscale; then
            warn "brew install tailscale failed. Falling back to cask discovery."
            return 1
        fi
    fi

    tailscale_bin="$(brew --prefix)/bin/tailscale"
    tailscaled_bin="$(brew --prefix)/bin/tailscaled"
    if [[ ! -x "$tailscale_bin" ]] || [[ ! -x "$tailscaled_bin" ]]; then
        warn "tailscale/tailscaled binaries not found under $(brew --prefix)/bin. Falling back."
        return 1
    fi

    mkdir -p "${HOME}/.config/tailscaled"
    mkdir -p "${HOME}/Library/Logs"
    TS_SOCKET="${HOME}/.config/tailscaled/tailscaled.sock"

    # Start userspace tailscaled if not already running for this user.
    if ! pgrep -u "$(id -u)" -f "tailscaled.*${TS_SOCKET}" >/dev/null 2>&1; then
        info "starting userspace tailscaled (no sudo, --tun=userspace-networking)"
        nohup "$tailscaled_bin" \
            --tun=userspace-networking \
            --socket="$TS_SOCKET" \
            --statedir="${HOME}/.config/tailscaled" \
            > "${HOME}/Library/Logs/tailscaled.log" 2>&1 &
        # Give the daemon a moment to create the socket.
        for _ in $(seq 1 20); do
            [[ -S "$TS_SOCKET" ]] && break
            sleep 0.5
        done
    fi

    if [[ ! -S "$TS_SOCKET" ]]; then
        warn "userspace tailscaled did not produce socket at $TS_SOCKET. Falling back."
        return 1
    fi

    TS_BIN="$tailscale_bin"
    info "userspace tailscaled up; CLI=${TS_BIN} socket=${TS_SOCKET}"
    return 0
}

ts_cli() {
    # Wrapper that routes to the userspace socket when set.
    if [[ -n "$TS_SOCKET" ]]; then
        "$TS_BIN" --socket="$TS_SOCKET" "$@"
    else
        "$TS_BIN" "$@"
    fi
}

if [[ "$MODE" == "userspace" ]]; then
    if ! try_install_userspace_tailscale; then
        warn "userspace mode unavailable — falling back to cask discovery."
        MODE="cask"
        SERVER_DEST="/usr/local/bin/macmini-server"
        CLIENT_DEST="/usr/local/bin/macmini-client"
    fi
fi

if [[ -z "$TS_BIN" ]]; then
    TS_CANDIDATES=(
        "/usr/local/bin/tailscale"
        "/opt/homebrew/bin/tailscale"
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale-IPN"
    )

    for candidate in "${TS_CANDIDATES[@]}"; do
        if [[ -x "$candidate" ]]; then
            TS_BIN="$candidate"
            break
        fi
    done

    if [[ -z "$TS_BIN" ]]; then
        err "Tailscale CLI not found in any of:"
        for c in "${TS_CANDIDATES[@]}"; do err "  $c"; done
        err "Install Tailscale (brew install tailscale, App Store, or tailscale.com/download),"
        err "sign in to your tailnet, then re-run this installer."
        exit 2
    fi
fi
info "Tailscale CLI: ${TS_BIN} (mode=${MODE})"

# In cask mode: if TS_BIN lives inside the .app bundle, drop a wrapper at
# /usr/local/bin/tailscale so the path survives Tailscale auto-updates.
# Userspace mode does not need this — brew formula installs to a stable path.
if [[ "$MODE" == "cask" && "$TS_BIN" == /Applications/Tailscale.app/* ]]; then
    WRAPPER="/usr/local/bin/tailscale"
    EXPECTED_CONTENT=$'#!/bin/sh\nexec "'"$TS_BIN"'" "$@"\n'

    need_wrapper=1
    if [[ -f "$WRAPPER" ]]; then
        existing="$(cat "$WRAPPER" 2>/dev/null || true)"
        if [[ "$existing" == "$EXPECTED_CONTENT" ]]; then
            need_wrapper=0
        fi
    fi

    if [[ $need_wrapper -eq 1 ]]; then
        info "Writing /usr/local/bin/tailscale wrapper (sudo) to survive app auto-updates."
        TMP_WRAP="$(mktemp)"
        printf '%s' "$EXPECTED_CONTENT" > "$TMP_WRAP"
        if sudo install -m 0755 "$TMP_WRAP" "$WRAPPER"; then
            info "wrapper installed at $WRAPPER"
        else
            warn "could not write wrapper at $WRAPPER (sudo declined?). Continuing with direct path."
        fi
        rm -f "$TMP_WRAP"
    fi
fi

# ---------------------------------------------------------------------------
# Step c: Tailscale online check.
# ---------------------------------------------------------------------------

if ! ts_cli status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null; then
    err "Tailscale is not online."
    if [[ "$MODE" == "userspace" ]]; then
        err "Run: ${TS_BIN} --socket=${TS_SOCKET} up"
        err "(Visit the printed auth URL in a browser to authorize this node.)"
    else
        err "Open Tailscale.app, sign in, ensure online, then re-run this installer."
    fi
    exit 2
fi
info "Tailscale online"

# ---------------------------------------------------------------------------
# Step d: read tailnet identity. Trim trailing dot from DNS name.
# Pick the first IPv4 from TailscaleIPs (the one containing '.'), not blindly index 0.
# ---------------------------------------------------------------------------

TS_STATUS_JSON="$(ts_cli status --json)"

TS_HOSTNAME="$(echo "$TS_STATUS_JSON" | jq -r '.Self.HostName')"
TS_DNS_NAME="$(echo "$TS_STATUS_JSON" | jq -r '.Self.DNSName' | sed 's/\.$//')"
TS_IP="$(echo "$TS_STATUS_JSON" | jq -r '.Self.TailscaleIPs[]? | select(contains("."))' | head -n 1)"

if [[ -z "$TS_HOSTNAME" || -z "$TS_DNS_NAME" || -z "$TS_IP" || \
      "$TS_HOSTNAME" == "null" || "$TS_DNS_NAME" == "null" || "$TS_IP" == "null" ]]; then
    err "could not read Self identity from tailscale status."
    err "  HostName=${TS_HOSTNAME}  DNSName=${TS_DNS_NAME}  IPv4=${TS_IP}"
    exit 2
fi

LISTEN_ADDR="${TS_IP}:8765"
info "Tailnet: ${TS_DNS_NAME} (${TS_IP}); LISTEN_ADDR=${LISTEN_ADDR}"

# ---------------------------------------------------------------------------
# Step e: token (generate only if missing OR --rotate-token).
# ---------------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ ! -f "$TOKEN_PATH" || $ROTATE_TOKEN -eq 1 ]]; then
    if [[ $ROTATE_TOKEN -eq 1 ]]; then
        info "rotating token (existing clients will need the new value)"
    else
        info "generating new bearer token"
    fi
    umask 077
    openssl rand -base64 32 | tr -d '\n' > "${TOKEN_PATH}.tmp"
    chmod 600 "${TOKEN_PATH}.tmp"
    mv -f "${TOKEN_PATH}.tmp" "$TOKEN_PATH"
else
    info "token already exists (preserving — pass --rotate-token to replace)"
fi

TOKEN_FP="$(token_fingerprint "$TOKEN_PATH")"

# ---------------------------------------------------------------------------
# Step f: install binaries (server + client) with sha-compare.
# ---------------------------------------------------------------------------

install_binary() {
    local component="$1"      # "server" or "client"
    local dest="$2"
    local src="${REPO}/skills/macmini/${component}/dist/macmini-${component}-darwin-${ARCH}"

    if [[ ! -f "$src" ]]; then
        info "binary missing: $src — building via make"
        if ! command -v go >/dev/null 2>&1; then
            err "Go not in PATH and pre-built binary missing: $src"
            err "Install Go (>=1.22) or ship a pre-built binary, then re-run."
            exit 2
        fi
        ( cd "${REPO}/skills/macmini/${component}" && make build )
        if [[ ! -f "$src" ]]; then
            err "build did not produce: $src"
            exit 2
        fi
    fi

    if [[ -f "$dest" ]]; then
        local src_sha dest_sha
        src_sha="$(sha256_file "$src")"
        dest_sha="$(sha256_file "$dest")"
        if [[ "$src_sha" == "$dest_sha" ]]; then
            info "${component} binary already current at ${dest}"
            return 0
        fi
    fi

    case "$dest" in
        "${HOME}/"*)
            info "installing ${component} → ${dest} (no sudo)"
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
            chmod 755 "$dest"
            ;;
        *)
            info "installing ${component} → ${dest} (sudo)"
            sudo cp "$src" "$dest"
            sudo chmod 755 "$dest"
            ;;
    esac
}

install_binary server "$SERVER_DEST"
install_binary client "$CLIENT_DEST"

# ---------------------------------------------------------------------------
# Step g: render plist via sed → tmp → cmp → mv only if different.
# ---------------------------------------------------------------------------

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    err "plist template missing: $PLIST_TEMPLATE"
    exit 2
fi

mkdir -p "$(dirname "$PLIST")"
TMP_PLIST="${PLIST}.tmp.$$"

# PATH for the LaunchAgent. Put ~/.local/bin first so userspace-mode binaries
# can shell out (e.g. /run uses /bin/zsh -lc which inherits this PATH).
LAUNCH_PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

sed \
    -e "s|@@BINARY_PATH@@|${SERVER_DEST}|g" \
    -e "s|@@TOKEN_PATH@@|${TOKEN_PATH}|g" \
    -e "s|@@LOG_PATH@@|${LOG_PATH}|g" \
    -e "s|@@LISTEN_ADDR@@|${LISTEN_ADDR}|g" \
    -e "s|@@PATH@@|${LAUNCH_PATH}|g" \
    "$PLIST_TEMPLATE" > "$TMP_PLIST"
chmod 644 "$TMP_PLIST"

PLIST_CHANGED=0
if [[ $REINSTALL -eq 1 ]] || ! cmp -s "$TMP_PLIST" "$PLIST" 2>/dev/null; then
    mv -f "$TMP_PLIST" "$PLIST"
    PLIST_CHANGED=1
    info "plist written: $PLIST"
else
    rm -f "$TMP_PLIST"
    info "plist unchanged: $PLIST"
fi

# Ensure log file's parent dir exists (launchd will create the file itself).
mkdir -p "$(dirname "$LOG_PATH")"

# ---------------------------------------------------------------------------
# Step j-pre: Screen Recording permission probe (BEFORE bootstrap so the TCC
# prompt fires under our interactive shell, not under launchd).
# ---------------------------------------------------------------------------

if [[ $SKIP_SCREENCAP_PROBE -eq 0 ]]; then
    info "probing Screen Recording permission (a TCC prompt may appear; click Allow)"
    rm -f "$PROBE_PNG"
    /usr/sbin/screencapture -x "$PROBE_PNG" 2>/dev/null || true

    # Poll up to 30s for the file to appear (in case the user is still clicking through).
    for _ in $(seq 1 30); do
        if [[ -s "$PROBE_PNG" ]]; then break; fi
        sleep 1
        /usr/sbin/screencapture -x "$PROBE_PNG" 2>/dev/null || true
    done

    if [[ ! -s "$PROBE_PNG" ]]; then
        warn "screencapture produced no file. Screen Recording permission likely DENIED."
        warn "Open System Settings → Privacy & Security → Screen Recording, enable"
        warn "  /usr/local/bin/macmini-server"
        warn "then run: launchctl kickstart -k gui/\$(id -u)/${LABEL}"
        warn "and re-run this installer to verify."
    else
        info "screencapture probe wrote ${PROBE_PNG} ($(stat -f%z "$PROBE_PNG") bytes)"
    fi
fi

# ---------------------------------------------------------------------------
# Step h: bootout-then-bootstrap (modern launchctl).
# ---------------------------------------------------------------------------

info "reloading LaunchAgent: ${LABEL}"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

# ---------------------------------------------------------------------------
# Step i: pmset (unless --skip-pmset).
# ---------------------------------------------------------------------------

if [[ $SKIP_PMSET -eq 0 ]]; then
    info "configuring power management (sudo pmset)"
    if sudo pmset -a sleep 0 displaysleep 30 disablesleep 1; then
        info "pmset applied: sleep=0 displaysleep=30 disablesleep=1"
    else
        warn "pmset failed (sudo declined?). The Mac mini may sleep and drop the server."
        warn "Re-run install.sh without --skip-pmset to retry."
    fi
else
    info "skipping pmset (--skip-pmset)"
fi

# ---------------------------------------------------------------------------
# Step k: smoke probe — health endpoint on the Tailscale interface.
# ---------------------------------------------------------------------------

info "smoke-testing http://${LISTEN_ADDR}/health"
healthy=0
for _ in $(seq 1 20); do
    if curl -sf "http://${LISTEN_ADDR}/health" >/dev/null 2>&1; then
        healthy=1
        break
    fi
    sleep 0.5
done

if [[ $healthy -ne 1 ]]; then
    err "server did not respond on http://${LISTEN_ADDR}/health within 10s."
    err "Last 50 log lines from ${LOG_PATH}:"
    if [[ -f "$LOG_PATH" ]]; then
        tail -n 50 "$LOG_PATH" >&2
    else
        err "  (log file does not exist yet)"
    fi
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    exit 3
fi
info "/health OK"

# ---------------------------------------------------------------------------
# Step j-post: post-bootstrap screencap probe via /shot endpoint.
# Verifies the server can capture the screen (not just the interactive shell).
# ---------------------------------------------------------------------------

if [[ $SKIP_SCREENCAP_PROBE -eq 0 ]]; then
    info "verifying /shot endpoint produces a non-black PNG"
    SHOT_TMP="$(mktemp -t macmini-shot).png"
    TOKEN_VAL="$(cat "$TOKEN_PATH")"
    if curl -sf -H "Authorization: Bearer ${TOKEN_VAL}" \
            "http://${LISTEN_ADDR}/shot" -o "$SHOT_TMP" 2>/dev/null; then
        # Verify PNG signature: bytes 0..7 == 89 50 4E 47 0D 0A 1A 0A
        sig="$(xxd -p -l 8 "$SHOT_TMP" 2>/dev/null || true)"
        if [[ "$sig" != "89504e470d0a1a0a" ]]; then
            warn "/shot did not return a PNG (signature: $sig). Check Screen Recording permission."
        else
            # Check mean pixel via sips (built into macOS). A black screencap suggests TCC denial.
            mean="$(sips -g pixelHeight -g pixelWidth "$SHOT_TMP" 2>/dev/null | awk '/pixel(Height|Width)/{print $2}' | head -n 1 || true)"
            # sips can't compute mean directly; use a coarser check — if file is suspiciously
            # small (<2KB for a real screen) flag it.
            sz="$(stat -f%z "$SHOT_TMP" 2>/dev/null || echo 0)"
            if [[ "$sz" -lt 2048 ]]; then
                warn "/shot returned a suspiciously small PNG (${sz} bytes; height=${mean}). Likely all-black."
                warn "Open System Settings → Privacy & Security → Screen Recording, enable"
                warn "  /usr/local/bin/macmini-server"
                warn "then: launchctl kickstart -k gui/\$(id -u)/${LABEL}"
            else
                info "/shot OK (${sz} bytes)"
            fi
        fi
    else
        warn "/shot request failed. Server may not have Screen Recording permission yet."
    fi
    rm -f "$SHOT_TMP"
fi

# ---------------------------------------------------------------------------
# Step l: install report + credentials block.
# ---------------------------------------------------------------------------

cat <<EOF

=== Mac mini server installed ===
Tailnet hostname:   ${TS_DNS_NAME}
Listen address:     ${LISTEN_ADDR}
Token fingerprint:  ${TOKEN_FP}   (NOT the token; install --print-token
                                   to dump once into 1Password.)
Plist:              ${PLIST}
Logs:               ${LOG_PATH}

Add to ~/.config/claude/credentials.md (paste this block, then store the actual
values in 1Password):

| Env Var               | op:// Reference                        | Used For                                 |
|-----------------------|----------------------------------------|------------------------------------------|
| CRD_PIN               | op://<VAULT>/Mac mini CRD/PIN          | CRD connection PIN (6 digits)            |
| CRD_MAC_MINI_HOSTNAME | op://<VAULT>/Mac mini CRD/Hostname     | ${TS_DNS_NAME} (Tailscale name for HTTP) |
| CRD_DEVICE_NAME       | op://<VAULT>/Mac mini CRD/Device Name  | CRD device-tile aria-label (often macOS hostname; check by visiting remotedesktop.google.com/access in your daily Chrome) |
| CRD_SERVER_TOKEN      | op://<VAULT>/Mac mini CRD/Server Token | Bearer for macmini-server                |

Then run on your dev machine:
  /load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN
Then verify: /macmini status

To capture the actual token value (one-time, for entering into 1Password):
  bash ${SCRIPT_DIR}/install.sh --print-token

=== Boot-survival note ===
The server runs as a per-user LaunchAgent. It auto-starts AT GUI LOGIN, not at
boot. For unattended reboot survival (server back up without you doing anything),
enable Automatic Login:
  System Settings → Users & Groups → Automatically log in as → ${USER}
If FileVault is on (default), the Mac will still require the FV password at
cold boot, then auto-login resumes from there.
EOF
