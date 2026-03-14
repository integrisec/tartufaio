#!/usr/bin/env bash
# ==============================================================================
# scan_smb_shares.sh
#
# Usage:
#   sudo ./tartufaio.sh -i <shares_file> -o <output_folder> [OPTIONS]
#
# ── Input file (-i): one UNC path per line ────────────────────────────────────
#   //server1/share1
#   //server2/share2
#   \\server3\share3        (backslashes are accepted)
#   # lines starting with # are ignored, as are blank lines
#
# ── Credentials file (-c): one credential set per line ───────────────────────
#   Format:  username:password[:domain]
#   The domain field is optional; it defaults to WORKGROUP when omitted.
#   Lines starting with # and blank lines are ignored.
#
#   Example:
#     # domain admin
#     CORP\jsmith:P@ssw0rd!:CORP
#     # local fallback account
#     administrator:Welcome1
#     # guest / null session
#     guest:
#
#   Each share is tried against every credential set in order.
#   The first successful mount wins; remaining credentials are skipped.
#   If no credential works the share is recorded in scan_errors.log.
#
# ── Options ───────────────────────────────────────────────────────────────────
#   -i <file>     Path to the UNC/SMB shares input file          (required)
#   -o <dir>      Path to the output folder for scan logs        (required)
#   -c <file>     Path to the credentials file                   (required
#                   unless -u/-p are used for a single credential)
#   -u <user>     Single SMB username  (alternative to -c)
#   -p <pass>     Single SMB password  (alternative to -c)
#   -d <domain>   SMB domain/workgroup used with -u/-p (default: WORKGROUP)
#   -m <dir>      Base directory for the mount point (default: /mnt/smb_scan)
#   -a            Try ALL credentials against every share, even after a
#                   successful mount. Each working credential gets its own
#                   scan and log file (e.g. trufflehog_server_share_2.log).
#   -h            Show this help message
#
# Requirements:
#   - Must be run as root (or with sudo) for mount/umount privileges
#   - cifs-utils must be installable via apt or yum/dnf
#   - Internet access to install trufflehog if not already present
# ==============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Defaults ───────────────────────────────────────────────────────────────────
INPUT_FILE=""
OUTPUT_DIR=""
CREDS_FILE=""
SINGLE_USER=""
SINGLE_PASS=""
SINGLE_DOMAIN="WORKGROUP"
MOUNT_BASE="/mnt/smb_scan"
MOUNT_POINT=""   # set in setup_mount_base
TRY_ALL=false    # set to true with -a

# Parallel arrays holding the parsed credential sets loaded at startup
CRED_USERS=()
CRED_PASSES=()
CRED_DOMAINS=()

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,2\}//'
    exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────────
while getopts ":i:o:c:u:p:d:m:ah" opt; do
    case $opt in
        i) INPUT_FILE="$OPTARG"   ;;
        o) OUTPUT_DIR="$OPTARG"   ;;
        c) CREDS_FILE="$OPTARG"   ;;
        u) SINGLE_USER="$OPTARG"  ;;
        p) SINGLE_PASS="$OPTARG"  ;;
        d) SINGLE_DOMAIN="$OPTARG";;
        m) MOUNT_BASE="$OPTARG"   ;;
        a) TRY_ALL=true           ;;
        h) usage ;;
        :) die "Option -$OPTARG requires an argument." ;;
        \?) die "Unknown option: -$OPTARG" ;;
    esac
done

# ── Privilege check ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo tartufaio.sh $*)"

# ── Validate required arguments ────────────────────────────────────────────────
[[ -n "$INPUT_FILE" ]] || die "Shares input file is required (-i)."
[[ -n "$OUTPUT_DIR" ]] || die "Output directory is required (-o)."
[[ -f "$INPUT_FILE" ]] || die "Shares input file not found: $INPUT_FILE"

# ── Load credentials ───────────────────────────────────────────────────────────
# Priority: -c file  >  -u/-p/-d flags  >  interactive prompt
load_credentials() {
    if [[ -n "$CREDS_FILE" ]]; then
        # ── Credentials file mode ──────────────────────────────────────────────
        [[ -f "$CREDS_FILE" ]] || die "Credentials file not found: $CREDS_FILE"

        local lineno=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            (( lineno++ )) || true
            # Trim leading/trailing whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            # Skip blanks and comments
            [[ -z "$line" || "$line" == \#* ]] && continue

            # Split on the first two colons only: user:pass[:domain]
            local u p d
            IFS=':' read -r u p d <<< "$line"

            # username is mandatory
            if [[ -z "$u" ]]; then
                warn "Credentials file line $lineno: empty username — skipping."
                continue
            fi

            # password may be empty (null session / guest)
            p="${p:-}"

            # domain defaults to WORKGROUP
            d="${d:-WORKGROUP}"

            CRED_USERS+=("$u")
            CRED_PASSES+=("$p")
            CRED_DOMAINS+=("$d")
        done < "$CREDS_FILE"

        local count="${#CRED_USERS[@]}"
        [[ $count -gt 0 ]] || die "No valid credential entries found in: $CREDS_FILE"
        info "Loaded $count credential set(s) from $CREDS_FILE"

    elif [[ -n "$SINGLE_USER" ]]; then
        # ── Single credential via flags ────────────────────────────────────────
        if [[ -z "$SINGLE_PASS" ]]; then
            read -rsp "SMB Password for '${SINGLE_USER}': " SINGLE_PASS
            echo
        fi
        CRED_USERS=("$SINGLE_USER")
        CRED_PASSES=("$SINGLE_PASS")
        CRED_DOMAINS=("$SINGLE_DOMAIN")
        info "Using single credential: ${SINGLE_USER}@${SINGLE_DOMAIN}"

    else
        # ── Interactive prompt ─────────────────────────────────────────────────
        warn "No credentials file (-c) or username (-u) provided."
        warn "Falling back to interactive single-credential entry."
        local u p d
        read -rp  "SMB Username: " u
        read -rsp "SMB Password: " p; echo
        read -rp  "SMB Domain   [WORKGROUP]: " d
        d="${d:-WORKGROUP}"
        CRED_USERS=("$u")
        CRED_PASSES=("$p")
        CRED_DOMAINS=("$d")
    fi
}

# ── Create output directory ────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" || die "Cannot create output directory: $OUTPUT_DIR"
info "Logs will be written to: $OUTPUT_DIR"

# ── Install cifs-utils if needed ───────────────────────────────────────────────
install_cifs_utils() {
    if ! command -v mount.cifs &>/dev/null; then
        info "Installing cifs-utils..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y cifs-utils
        elif command -v dnf &>/dev/null; then
            dnf install -y cifs-utils
        elif command -v yum &>/dev/null; then
            yum install -y cifs-utils
        else
            die "Cannot install cifs-utils: no supported package manager found (apt/dnf/yum)."
        fi
        success "cifs-utils installed."
    else
        success "cifs-utils already installed."
    fi
}

# ── Install TruffleHog if needed ───────────────────────────────────────────────
install_trufflehog() {
    if command -v trufflehog &>/dev/null; then
        success "TruffleHog already installed: $(trufflehog --version 2>&1 | head -1)"
        return
    fi

    info "TruffleHog not found. Installing..."

    if command -v curl &>/dev/null; then
        curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
            | sh -s -- -b /usr/local/bin
    elif command -v wget &>/dev/null; then
        wget -qO- https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh \
            | sh -s -- -b /usr/local/bin
    else
        die "Neither curl nor wget is available. Install one and retry."
    fi

    command -v trufflehog &>/dev/null \
        || die "TruffleHog installation failed — binary not found in PATH."
    success "TruffleHog installed: $(trufflehog --version 2>&1 | head -1)"
}

# ── Create mount base directory ────────────────────────────────────────────────
setup_mount_base() {
    MOUNT_POINT="${MOUNT_BASE}/target"
    if [[ -d "$MOUNT_POINT" ]]; then
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            warn "Something is already mounted at $MOUNT_POINT — attempting unmount."
            umount "$MOUNT_POINT" || die "Cannot unmount existing share at $MOUNT_POINT"
        fi
    else
        mkdir -p "$MOUNT_POINT" || die "Cannot create mount point: $MOUNT_POINT"
    fi
    info "Mount point: $MOUNT_POINT"
}

# ── Cleanup: unmount & remove mount base ───────────────────────────────────────
cleanup() {
    if [[ -n "$MOUNT_POINT" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        warn "Cleaning up: unmounting $MOUNT_POINT"
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    if [[ -d "$MOUNT_BASE" ]]; then
        rm -rf "$MOUNT_BASE" && info "Removed mount base: $MOUNT_BASE"
    fi
}
trap cleanup EXIT

# ── Convert UNC path to CIFS-friendly format ───────────────────────────────────
normalize_unc() {
    local raw="$1"
    echo "${raw//\\//}"
}

# ── Derive a safe log filename from a UNC path ─────────────────────────────────
# //server.domain.com/share/subdir  →  trufflehog_server.domain.com_share.log
# Only the server and share fields are used; any sub-path is intentionally ignored.
log_filename() {
    local unc="$1"
    # Strip leading slashes (normalised input always has //)
    local stripped="${unc#//}"
    # First path component = server, second = share
    local server="${stripped%%/*}"
    local remainder="${stripped#*/}"
    local share="${remainder%%/*}"
    echo "trufflehog_${server}_${share}.log"
}

# ── Try to mount a share with one credential set ───────────────────────────────
# Returns 0 on success, 1 on failure.
try_mount() {
    local unc="$1" user="$2" pass="$3" domain="$4"

    # Attempt SMBv3 first, then fall back to kernel-negotiated version
    if mount -t cifs "$unc" "$MOUNT_POINT" \
            -o "username=${user},password=${pass},domain=${domain},ro,vers=3.0" \
            2>/dev/null; then
        return 0
    fi

    if mount -t cifs "$unc" "$MOUNT_POINT" \
            -o "username=${user},password=${pass},domain=${domain},ro" \
            2>/dev/null; then
        return 0
    fi

    return 1
}

# ── Run TruffleHog against the currently-mounted share and write a log ─────────
# Args: $1 = unc  $2 = credential label  $3 = log file path
run_scan() {
    local unc="$1" cred_label="$2" logfile="$3"

    info "Scanning with TruffleHog (credential: ${cred_label})..."

    {
        echo "# TruffleHog scan of: $unc"
        echo "# Mounted with:       $cred_label"
        echo "# Scan started:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# ─────────────────────────────────────────────"
    } > "$logfile"

    if trufflehog filesystem "$MOUNT_POINT" 2>&1 | tee -a "$logfile"; then
        success "Scan complete — log: $logfile"
    else
        warn "TruffleHog exited non-zero (check $logfile)"
        echo "[SCAN ERROR]   $unc  (credential: ${cred_label})" \
            >> "${OUTPUT_DIR}/scan_errors.log"
    fi
}

# ── Unmount helper ─────────────────────────────────────────────────────────────
do_umount() {
    local unc="$1"
    info "Unmounting $MOUNT_POINT ..."
    if umount "$MOUNT_POINT"; then
        success "Unmounted $unc"
    else
        warn "umount failed — trying lazy unmount"
        umount -l "$MOUNT_POINT" || error "Lazy unmount also failed for $MOUNT_POINT"
    fi
}

# ── Scan a single share (iterating through credential sets) ────────────────────
# In default mode: stop at the first successful credential.
# With -a (TRY_ALL): attempt every credential, scanning once per working set.
scan_share() {
    local unc_raw="$1"
    local unc
    unc=$(normalize_unc "$unc_raw")

    local base_log="${OUTPUT_DIR}/$(log_filename "$unc")"
    local cred_count="${#CRED_USERS[@]}"
    local any_mounted=false
    local scan_index=0   # counts successful scans for unique log naming

    info "──────────────────────────────────────────────────"
    info "Target   : $unc"
    info "Mode     : $( [[ "$TRY_ALL" == true ]] && echo "try ALL credentials (-a)" || echo "stop at first success" )"
    info "Trying $cred_count credential set(s)..."

    local i
    for (( i = 0; i < cred_count; i++ )); do
        local u="${CRED_USERS[$i]}"
        local p="${CRED_PASSES[$i]}"
        local d="${CRED_DOMAINS[$i]}"
        local cred_label="${u}@${d}"

        info "  [$((i+1))/$cred_count] Trying: ${cred_label} ..."

        if ! try_mount "$unc" "$u" "$p" "$d"; then
            warn "  Credential set $((i+1)) failed: ${cred_label}"
            continue
        fi

        success "  Mounted with credential set $((i+1)): ${cred_label}"
        any_mounted=true
        (( scan_index++ )) || true

        # Build a unique log file name:
        #   first success  →  trufflehog_server_share.log
        #   subsequent     →  trufflehog_server_share_2.log, _3.log, …
        local logfile
        if [[ $scan_index -eq 1 ]]; then
            logfile="$base_log"
        else
            logfile="${base_log%.log}_${scan_index}.log"
        fi

        run_scan "$unc" "$cred_label" "$logfile"
        do_umount "$unc"

        # In default (first-success) mode, stop here
        if [[ "$TRY_ALL" == false ]]; then
            break
        fi

        info "  (-a) Continuing to next credential set..."
    done

    if [[ "$any_mounted" == false ]]; then
        error "All $cred_count credential set(s) exhausted — cannot mount $unc"
        echo "[MOUNT FAILED] $unc  (tried $cred_count credential set(s))" \
            >> "${OUTPUT_DIR}/scan_errors.log"
        return 1
    fi

    [[ "$TRY_ALL" == true ]] && \
        info "Completed $scan_index successful scan(s) for $unc"

    return 0
}

# ── ASCII art banner ──────────────────────────────────────────────────────────
print_banner() {
    cat << 'BANNER'

  +------------------------------------------------------------------+
  |                                                                  |
  |                    T  A  R  T  U  F  A  I  O                     |
  |                     SMB Share Secret Scanner                     |
  |                    "il cacciatore di tartufi"                    |
  |                                                                  |
  |          _______                                                 |
  |         (_______) .---.                                          |
  |         ( o   o )/     \           _______                       |
  |          \ ___ / | BAG |          / o   o \                      |
  |           \___/   \___/          (  (vvv)  )~~  *sniff sniff*    |
  |           /| |\     |             \_______/                      |
  |          / | | \    | <-- stick      | |                         |
  |         /  | |  \   |            ~~~-+-+~~~                      |
  |        /___|_|___\  |                                            |
  |                     |                                            |
  +------------------------------------------------------------------+

BANNER
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    print_banner

    load_credentials
    install_cifs_utils
    install_trufflehog
    setup_mount_base

    local total=0 success_count=0 fail_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        (( total++ )) || true

        if scan_share "$line"; then
            (( success_count++ )) || true
        else
            (( fail_count++ )) || true
        fi

    done < "$INPUT_FILE"

    echo
    echo -e "${BOLD}=== Scan Summary ===${RESET}"
    echo -e "  Total shares      : ${total}"
    echo -e "  ${GREEN}Succeeded${RESET}         : ${success_count}"
    echo -e "  ${RED}Failed${RESET}            : ${fail_count}"
    echo -e "  Credential sets   : ${#CRED_USERS[@]}"
    echo -e "  Mode              : $( [[ "$TRY_ALL" == true ]] && echo "try ALL credentials (-a)" || echo "stop at first success" )"
    echo -e "  Output folder     : ${OUTPUT_DIR}"
    [[ -f "${OUTPUT_DIR}/scan_errors.log" ]] && \
        echo -e "  ${YELLOW}Error log${RESET}         : ${OUTPUT_DIR}/scan_errors.log"
    echo
}

main "$@"