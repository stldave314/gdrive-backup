#!/usr/bin/env bash
# gdrive-backup — encrypted incremental Google Drive backup/restore for Linux

set -uo pipefail

VERSION="1.0.0"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gdrive-backup"
CONFIG_FILE="$CONFIG_DIR/config"
PROFILES_DIR="$CONFIG_DIR/profiles"
EXCLUDE_FILE="$CONFIG_DIR/exclude.conf"
LOG_FILE="$CONFIG_DIR/backup.log"

GDRIVE_REMOTE="gdrive-backup"
CRYPT_REMOTE="gdrive-backup-crypt"
DRIVE_BASE_PATH="gdrive-backup"
CURRENT_PROFILE=""
BACKUP_METHOD="B"
KEEP_VERSIONS=5
BACKUP_SYSTEM=false

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

# ── Colors ────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Print helpers ─────────────────────────────────────────────

print_header() {
    local width=50
    local line
    printf -v line '%*s' "$width" ''; line="${line// /═}"
    echo -e "\n${BOLD}${BLUE}${line}${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}${line}${NC}\n"
}

print_step()  { echo -e "${CYAN}▶ $1${NC}"; }
print_ok()    { echo -e "${GREEN}✓ $1${NC}"; }
print_warn()  { echo -e "${YELLOW}⚠  $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}" >&2; }
print_info()  { echo -e "  $1"; }
print_dim()   { echo -e "${DIM}  $1${NC}"; }

ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn_prompt
    [[ "$default" == "y" ]] && yn_prompt="${GREEN}[Y/n]${NC}" || yn_prompt="${YELLOW}[y/N]${NC}"
    while true; do
        local answer
        read -r -p "$(echo -e "  ${YELLOW}?${NC} $prompt $yn_prompt: ")" answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) print_error "Please answer y or n." ;;
        esac
    done
}

ask_value() {
    local prompt="$1" default="${2:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[${default}]${NC}"
    local value
    read -r -p "$(echo -e "  ${YELLOW}?${NC} $prompt${display_default}: ")" value
    echo "${value:-$default}"
}

ask_number() {
    local prompt="$1" default="$2" min="${3:-1}" max="${4:-999}"
    while true; do
        local val
        val=$(ask_value "$prompt" "$default")
        if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge "$min" ]] && [[ "$val" -le "$max" ]]; then
            echo "$val"
            return
        fi
        print_error "Please enter a number between $min and $max."
    done
}

_read_masked() {
    # Reads a password character by character, printing * for each keystroke.
    # All display goes to /dev/tty so the actual value can be captured via $().
    local prompt="$1" password="" char
    printf '%b' "  ${YELLOW}?${NC} $prompt: " > /dev/tty
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then                          # Enter
            break
        elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then  # Backspace
            if [[ ${#password} -gt 0 ]]; then
                password="${password%?}"
                printf '\b \b' > /dev/tty
            fi
        elif [[ "$char" == $'\x15' ]]; then                # Ctrl+U — clear
            local i; for ((i=0; i<${#password}; i++)); do printf '\b \b' > /dev/tty; done
            password=""
        else
            password+="$char"
            printf '*' > /dev/tty
        fi
    done
    printf '\n' > /dev/tty
    printf '%s' "$password"
}

ask_password() {
    local prompt="$1"
    while true; do
        local p1 p2
        p1=$(_read_masked "$prompt")
        p2=$(_read_masked "Confirm")
        if [[ "$p1" == "$p2" ]]; then
            [[ -z "$p1" ]] && { print_error "Password cannot be empty."; continue; }
            printf '%s' "$p1"
            return
        fi
        print_error "Passwords do not match."
    done
}

_rclone_obscure() {
    # Implements rclone's obscure format (AES-256-CTR + base64url) without ever
    # placing the password in a process argument list.
    #
    # How it stays out of `ps` / /proc/*/cmdline:
    #   - `printf '%s' "$1"` is a bash builtin — no child process is forked, so
    #     the password value never appears in any process's argv.
    #   - The data reaches `openssl enc` via an anonymous pipe as stdin.
    #   - openssl's own args are only the key and IV, neither of which is secret
    #     (the key is hardcoded in rclone's public source; the IV is random and
    #     included unencrypted in the output anyway).
    #
    # The key below is rclone's own hardcoded obscure key from its source code.
    # It is NOT a secret — it provides obfuscation only, not encryption.
    local _key="9c935b48730a554d6bfd7c63c886a92bd0906d9faac84cde31b3a39e33361d5c"
    local _iv
    _iv=$(openssl rand -hex 16)
    printf '%s' "$1" \
        | openssl enc -aes-256-ctr -K "$_key" -iv "$_iv" -nosalt -nopad 2>/dev/null \
        | python3 -c "
import sys, base64
iv = bytes.fromhex('${_iv}')
sys.stdout.write(base64.urlsafe_b64encode(iv + sys.stdin.buffer.read()).rstrip(b'=').decode())
"
}

ask_choice() {
    # ask_choice "prompt" default opt1 opt2 ...
    local prompt="$1" default="$2"; shift 2
    local opts=("$@")
    while true; do
        local val
        val=$(ask_value "$prompt" "$default")
        val="${val^^}"
        for opt in "${opts[@]}"; do
            [[ "${opt^^}" == "$val" ]] && { echo "$val"; return; }
        done
        print_error "Please enter one of: ${opts[*]}"
    done
}

# ── Dependencies ──────────────────────────────────────────────

check_deps() {
    print_step "Checking dependencies..."
    local missing=()
    for cmd in rsync tar curl openssl python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v rclone &>/dev/null || missing+=("rclone")

    if [[ ${#missing[@]} -eq 0 ]]; then
        print_ok "All dependencies present."
        return
    fi

    print_warn "Missing: ${missing[*]}"
    ask_yes_no "Install missing dependencies now?" || {
        print_error "Cannot continue without required dependencies."
        exit 1
    }

    # rclone via official installer
    if printf '%s\n' "${missing[@]}" | grep -q '^rclone$'; then
        print_step "Installing rclone from rclone.org..."
        curl -fsSL https://rclone.org/install.sh | sudo bash
    fi

    # Remaining via apt
    local apt_pkgs=()
    for pkg in "${missing[@]}"; do
        [[ "$pkg" != "rclone" ]] && apt_pkgs+=("$pkg")
    done
    [[ ${#apt_pkgs[@]} -gt 0 ]] && sudo apt-get install -y "${apt_pkgs[@]}"

    print_ok "Dependencies installed."
}

# ── Config ────────────────────────────────────────────────────

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# gdrive-backup config — $(date)
GDRIVE_REMOTE="$GDRIVE_REMOTE"
CRYPT_REMOTE="$CRYPT_REMOTE"
DRIVE_BASE_PATH="$DRIVE_BASE_PATH"
CURRENT_PROFILE="$CURRENT_PROFILE"
BACKUP_METHOD="$BACKUP_METHOD"
KEEP_VERSIONS="$KEEP_VERSIONS"
BACKUP_SYSTEM="$BACKUP_SYSTEM"
EOF
    chmod 600 "$CONFIG_FILE"
}

load_profile_config() {
    local profile="$1"
    local pfile="$PROFILES_DIR/$profile/config"
    [[ -f "$pfile" ]] || return
    # shellcheck source=/dev/null
    source "$pfile"
}

save_profile_config() {
    local profile="$1"
    mkdir -p "$PROFILES_DIR/$profile"
    cat > "$PROFILES_DIR/$profile/config" <<EOF
# Profile: $profile — $(date)
PROFILE_NAME="$profile"
BACKUP_METHOD="$BACKUP_METHOD"
KEEP_VERSIONS="$KEEP_VERSIONS"
BACKUP_SYSTEM="$BACKUP_SYSTEM"
EOF
    chmod 600 "$PROFILES_DIR/$profile/config"

    # Save separate large-dirs list (one per line)
    printf '%s\n' "${SEPARATE_LARGE_DIRS[@]+"${SEPARATE_LARGE_DIRS[@]}"}" \
        > "$PROFILES_DIR/$profile/large-dirs-separate.conf"
}

load_separate_large_dirs() {
    local profile="$1"
    local lfile="$PROFILES_DIR/$profile/large-dirs-separate.conf"
    SEPARATE_LARGE_DIRS=()
    [[ -f "$lfile" ]] || return
    mapfile -t SEPARATE_LARGE_DIRS < "$lfile"
}

# ── Profile selection ─────────────────────────────────────────

select_or_create_profile() {
    print_header "Profile Setup"
    print_info "Profiles let you restore to a different machine or hostname."
    print_info "Use a memorable name — e.g. ${BOLD}work-laptop${NC}, ${BOLD}home-desktop${NC}."
    echo

    local existing=()
    if [[ -d "$PROFILES_DIR" ]]; then
        mapfile -t existing < <(find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    fi

    if [[ ${#existing[@]} -gt 0 ]]; then
        print_info "Local profiles:"
        for i in "${!existing[@]}"; do
            echo -e "  ${BOLD}$((i+1)).${NC} ${existing[$i]}"
        done
        echo -e "  ${BOLD}$((${#existing[@]}+1)).${NC} Create new profile"
        echo
        local choice
        choice=$(ask_number "Select" "1" 1 $((${#existing[@]}+1)))
        if [[ "$choice" -le "${#existing[@]}" ]]; then
            CURRENT_PROFILE="${existing[$((choice-1))]}"
            print_ok "Profile selected: $CURRENT_PROFILE"
            load_profile_config "$CURRENT_PROFILE"
            return
        fi
    fi

    local default_name
    default_name=$(hostname -s)
    CURRENT_PROFILE=$(ask_value "New profile name" "$default_name")
    [[ -z "$CURRENT_PROFILE" ]] && CURRENT_PROFILE="$default_name"
    print_ok "Profile '$CURRENT_PROFILE' will be created."
}

# ── rclone setup ──────────────────────────────────────────────

setup_rclone_drive() {
    print_header "Google Drive Authentication"

    if rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE}:$"; then
        print_ok "Drive remote '${GDRIVE_REMOTE}' already exists."
        ask_yes_no "Reconfigure it?" "n" || return
        rclone config delete "$GDRIVE_REMOTE" 2>/dev/null || true
    fi

    echo
    print_info "rclone will print a URL below. Copy it and open it in any browser."
    print_info "Log in to Google, grant access, and rclone will complete automatically."
    echo
    print_info "Access requested: ${BOLD}drive.file${NC} scope only."
    print_info "This means rclone can only see files it creates — not your existing"
    print_info "Drive contents. Backups will not be visible in the Drive web UI."
    echo
    print_warn "Make sure you are logged into the correct Google account before proceeding."
    echo
    read -r -p "$(echo -e "  ${YELLOW}Press ENTER to generate the authorization URL...${NC}")"
    echo

    RCLONE_AUTH_NO_OPEN_BROWSER=true rclone config create "$GDRIVE_REMOTE" drive \
        scope="drive.file"

    if ! rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE}:$"; then
        print_error "Drive remote was not created. Run 'rclone config' manually to diagnose."
        exit 1
    fi

    print_ok "Google Drive remote '${GDRIVE_REMOTE}' configured."
}

setup_rclone_crypt() {
    print_header "Encryption Setup"
    print_info "Your backups are encrypted with rclone crypt before reaching Google Drive."
    print_info "You need two passwords:"
    echo
    echo -e "  ${BOLD}Main password${NC}   — encrypts file contents. Use a strong passphrase."
    echo -e "  ${BOLD}Salt password${NC}   — scrambles filenames on Drive. Can be shorter."
    echo
    print_warn "IMPORTANT: Without both passwords your backup CANNOT be decrypted."
    print_warn "Write them down and store them somewhere safe before continuing."
    echo
    read -r -p "$(echo -e "  ${YELLOW}Press ENTER when you have saved your passwords...${NC}")"
    echo

    if rclone listremotes 2>/dev/null | grep -q "^${CRYPT_REMOTE}:$"; then
        print_ok "Crypt remote '${CRYPT_REMOTE}' already exists."
        ask_yes_no "Reconfigure it?" "n" || return
    fi

    local pass1 pass2
    pass1=$(ask_password "Main encryption password")
    pass2=$(ask_password "Salt password")

    print_step "Configuring encryption..."

    # Disable xtrace for this block so `bash -x` cannot print password values.
    { set +x; } 2>/dev/null

    local obs1 obs2
    obs1=$(_rclone_obscure "$pass1")
    obs2=$(_rclone_obscure "$pass2")

    # Write the crypt remote directly into rclone's config file using only bash
    # builtins (printf). No external process receives obs1/obs2 as an argument —
    # they stay as bash variables until written to the file descriptor.
    local _rclone_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf"
    mkdir -p "$(dirname "$_rclone_cfg")"

    # Strip any existing crypt section so reconfiguration is clean.
    if [[ -f "$_rclone_cfg" ]]; then
        local _tmp
        _tmp=$(mktemp)
        awk -v section="[${CRYPT_REMOTE}]" '
            $0 == section { skip=1; next }
            skip && /^\[/ { skip=0 }
            !skip         { print }
        ' "$_rclone_cfg" > "$_tmp" && mv "$_tmp" "$_rclone_cfg"
    fi

    # Append the new section. Every line here uses bash printf builtins —
    # obs1 and obs2 are bash variables written to a file descriptor, not
    # passed as arguments to any child process.
    {
        printf '\n[%s]\n'                    "$CRYPT_REMOTE"
        printf 'type = crypt\n'
        printf 'remote = %s:%s\n'            "$GDRIVE_REMOTE" "$DRIVE_BASE_PATH"
        printf 'filename_encryption = standard\n'
        printf 'directory_name_encryption = true\n'
        printf 'password = %s\n'             "$obs1"
        printf 'password2 = %s\n'            "$obs2"
    } >> "$_rclone_cfg"

    chmod 600 "$_rclone_cfg"

    # Wipe all sensitive variables from bash memory.
    unset pass1 pass2 obs1 obs2

    print_ok "Encryption configured."
}

# ── Backup method selection ───────────────────────────────────

select_backup_method() {
    print_header "Backup Method"

    echo -e "  ${BOLD}A${NC}  Hardlink snapshots  ${DIM}(rsync + local staging, then upload)${NC}"
    print_info "     Every version looks like a complete snapshot. Unchanged files share"
    print_info "     disk space locally via hardlinks. On Google Drive each version is a"
    print_info "     full copy — storage cost multiplies with each version kept."
    print_dim "     Best if you have a local drive as primary; Drive is just offsite."
    echo
    echo -e "  ${BOLD}B${NC}  rclone sync + backup-dir  ${GREEN}[Recommended]${NC}"
    print_info "     Drive always mirrors your current home directory. Files you change"
    print_info "     or delete are moved to a timestamped versions folder instead of"
    print_info "     erased — so history is kept. Only changed files are uploaded each run."
    print_dim "     Caveat: can't restore an exact full snapshot; restores current state"
    print_dim "     plus per-file history. Best for most people."
    echo
    echo -e "  ${BOLD}C${NC}  Encrypted tar archives"
    print_info "     Full backup = one compressed+encrypted .tar.gz file on Drive."
    print_info "     Incremental = a smaller archive of only files changed since last full."
    print_dim "     Caveat: must download entire archive to restore anything. Slowest"
    print_dim "     restore. Best for long-term archival, not day-to-day use."
    echo

    BACKUP_METHOD=$(ask_choice "Select method (A/B/C)" "B" A B C)
    print_ok "Method $BACKUP_METHOD selected."
}

# ── Version retention ─────────────────────────────────────────

setup_versions() {
    print_header "Version Retention"
    print_info "How many backup versions (snapshots / version dirs / archives) to keep?"
    print_info "Older versions beyond this count are permanently deleted from Drive."
    echo
    KEEP_VERSIONS=$(ask_number "Versions to keep" "5" 1 999)
    print_ok "Keeping $KEEP_VERSIONS version(s)."
}

# ── Exclusion + large dir setup ───────────────────────────────

# Directories to ask about individually
CANDIDATE_LARGE_DIRS=(
    "Downloads"
    ".cache"
    ".local/share/Trash"
    ".local/share/Steam"
    "Videos"
    "snap"
    ".var/app"
)

SEPARATE_LARGE_DIRS=()

STANDARD_EXCLUDES=(
    ".thumbnails/**"
    ".local/share/recently-used.xbel"
    "**/.git/**"
    "**/node_modules/**"
    "**/__pycache__/**"
    "**/*.pyc"
    ".mozilla/firefox/*/Cache/**"
    ".mozilla/firefox/*/cache2/**"
    ".config/google-chrome/*/Cache/**"
    ".config/chromium/*/Cache/**"
    ".config/Code/Cache/**"
    ".config/Code/CachedData/**"
)

setup_exclusions() {
    print_header "Exclusion & Large Directory Setup"
    print_info "The following are always excluded (caches, thumbnails, VCS data):"
    for ex in "${STANDARD_EXCLUDES[@]}"; do
        print_dim "  $ex"
    done
    echo

    # Write standard excludes
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "${STANDARD_EXCLUDES[@]}" > "$EXCLUDE_FILE"

    print_info "For each large directory below you can choose:"
    print_info "  • Include in main backup  (counts against its size)"
    print_info "  • Back up separately      (restore independently from main)"
    print_info "  • Skip entirely"
    echo

    SEPARATE_LARGE_DIRS=()

    for dir in "${CANDIDATE_LARGE_DIRS[@]}"; do
        [[ -d "$HOME/$dir" ]] || continue
        local size
        size=$(du -sh "$HOME/$dir" 2>/dev/null | cut -f1)
        echo -e "  ${BOLD}~/$dir${NC}  (${CYAN}${size}${NC})"

        if ask_yes_no "  Back up ~/$dir?" "n"; then
            if ask_yes_no "  Store separately (can restore independently)?" "y"; then
                SEPARATE_LARGE_DIRS+=("$dir")
                echo "${dir}/**" >> "$EXCLUDE_FILE"
                print_ok "  Will back up ~/$dir separately."
            else
                print_ok "  Will include ~/$dir in main backup."
            fi
        else
            echo "${dir}/**" >> "$EXCLUDE_FILE"
            print_dim "  Skipping ~/$dir."
        fi
        echo
    done

    print_ok "Exclude list saved: $EXCLUDE_FILE"
}

# ── System state backup option ────────────────────────────────

setup_system_backup() {
    print_header "System State Backup (Optional)"
    print_info "Beyond your home directory, you can also back up:"
    print_info "  • /etc              system configuration"
    print_info "  • User crontab"
    print_info "  • /usr/local/bin    custom scripts"
    echo
    print_warn "This requires sudo. The /etc backup excludes /etc/ssl/private."
    echo
    if ask_yes_no "Enable system state backup?" "n"; then
        BACKUP_SYSTEM=true
        print_ok "System backup enabled."
    else
        BACKUP_SYSTEM=false
        print_dim "System backup disabled."
    fi
}

# ── Package management ────────────────────────────────────────

export_packages() {
    local dest="$1"
    mkdir -p "$dest"

    print_step "Exporting manually-installed apt packages..."
    apt-mark showmanual 2>/dev/null > "$dest/apt-packages.txt" || true
    local apt_count
    apt_count=$(wc -l < "$dest/apt-packages.txt" 2>/dev/null || echo 0)
    print_ok "$apt_count apt packages saved."

    print_step "Exporting apt sources..."
    cp /etc/apt/sources.list "$dest/sources.list" 2>/dev/null || true
    if [[ -d /etc/apt/sources.list.d ]]; then
        cp -r /etc/apt/sources.list.d/ "$dest/sources.list.d/" 2>/dev/null || true
    fi

    print_step "Exporting apt signing keys..."
    mkdir -p "$dest/apt-keys"
    if [[ -d /etc/apt/trusted.gpg.d ]]; then
        cp /etc/apt/trusted.gpg.d/*.gpg "$dest/apt-keys/" 2>/dev/null || true
        cp /etc/apt/trusted.gpg.d/*.asc "$dest/apt-keys/" 2>/dev/null || true
    fi
    apt-key exportall > "$dest/apt-keys/all-legacy.gpg" 2>/dev/null || true

    if command -v flatpak &>/dev/null; then
        print_step "Exporting Flatpak apps and remotes..."
        flatpak list --app --columns=application \
            > "$dest/flatpak-packages.txt" 2>/dev/null || true
        flatpak remotes --columns=name,url \
            > "$dest/flatpak-remotes.txt" 2>/dev/null || true
        local fp_count
        fp_count=$(wc -l < "$dest/flatpak-packages.txt" 2>/dev/null || echo 0)
        print_ok "$fp_count Flatpak apps saved."
    fi
}

install_packages() {
    local src="$1"

    if [[ -f "$src/flatpak-remotes.txt" ]] && command -v flatpak &>/dev/null; then
        print_step "Restoring Flatpak remotes..."
        while IFS=$'\t ' read -r name url rest; do
            [[ "$name" == "Name" || -z "$name" ]] && continue
            flatpak remote-add --if-not-exists "$name" "$url" 2>/dev/null || \
                print_warn "Could not add remote '$name' — may need manual setup."
        done < "$src/flatpak-remotes.txt"
    fi

    if [[ -f "$src/flatpak-packages.txt" ]] && command -v flatpak &>/dev/null; then
        print_step "Installing Flatpak apps..."
        while IFS= read -r app; do
            [[ -z "$app" || "$app" == "Application" ]] && continue
            flatpak install -y --noninteractive "$app" 2>/dev/null || \
                print_warn "Could not install Flatpak: $app"
        done < "$src/flatpak-packages.txt"
        print_ok "Flatpak apps installed."
    fi

    if [[ -f "$src/apt-packages.txt" ]]; then
        if ask_yes_no "Restore apt sources before installing packages?"; then
            print_step "Restoring apt sources..."
            [[ -f "$src/sources.list" ]] && \
                sudo cp "$src/sources.list" /etc/apt/sources.list
            [[ -d "$src/sources.list.d" ]] && \
                sudo cp -r "$src/sources.list.d/." /etc/apt/sources.list.d/
            if [[ -d "$src/apt-keys" ]]; then
                find "$src/apt-keys" -name '*.gpg' -exec \
                    sudo cp {} /etc/apt/trusted.gpg.d/ \; 2>/dev/null || true
                find "$src/apt-keys" -name '*.asc' -exec \
                    sudo cp {} /etc/apt/trusted.gpg.d/ \; 2>/dev/null || true
            fi
            sudo apt-get update
        fi

        print_step "Installing apt packages..."
        # Read packages into array to handle spaces/blank lines safely
        local pkgs=()
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" == \#* ]] && continue
            pkgs+=("$pkg")
        done < "$src/apt-packages.txt"

        if [[ ${#pkgs[@]} -gt 0 ]]; then
            sudo apt-get install -y "${pkgs[@]}" || \
                print_warn "Some packages could not be installed. Check output above."
        fi
        print_ok "apt packages installed."
    fi
}

# ── Remote path helpers ───────────────────────────────────────

r_home_current()   { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/home/current"; }
r_home_versions()  { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/home/versions"; }
r_home_snapshots() { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/home/snapshots"; }
r_home_archives()  { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/home/archives"; }
r_system()         { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/system"; }
r_packages()       { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/packages"; }
r_large_dirs()     { echo "${CRYPT_REMOTE}:profiles/${CURRENT_PROFILE}/large-dirs"; }

# ── Pruning ───────────────────────────────────────────────────

prune_remote_versions() {
    local remote_path="$1" keep="$2"
    local entries=()
    mapfile -t entries < <(
        rclone lsd "$remote_path" 2>/dev/null \
            | awk '{print $NF}' | sort
    )
    local count=${#entries[@]}
    if [[ $count -le $keep ]]; then
        print_dim "Version count ($count) within limit ($keep). No pruning needed."
        return
    fi
    local excess=$(( count - keep ))
    print_step "Pruning $excess old version(s) from $(basename "$remote_path")..."
    for i in $(seq 0 $(( excess - 1 ))); do
        rclone purge "${remote_path}/${entries[$i]}" 2>/dev/null && \
            print_dim "  Deleted: ${entries[$i]}"
    done
}

# ── Backup: Method A (hardlink snapshots) ─────────────────────

backup_method_a() {
    local staging="$CONFIG_DIR/staging/snapshots"
    mkdir -p "$staging"

    print_step "Method A: creating rsync hardlink snapshot..."
    local prev
    prev=$(find "$staging" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)

    local curr="$staging/$TIMESTAMP"
    mkdir -p "$curr"

    if [[ -n "$prev" ]]; then
        rsync -aHAX --link-dest="$prev" \
            --exclude-from="$EXCLUDE_FILE" \
            --progress \
            "$HOME/" "$curr/"
    else
        rsync -aHAX \
            --exclude-from="$EXCLUDE_FILE" \
            --progress \
            "$HOME/" "$curr/"
    fi

    print_step "Uploading snapshot to Drive..."
    rclone sync "$curr/" "$(r_home_snapshots)/${TIMESTAMP}/" \
        --progress --stats-one-line \
        --log-file "$LOG_FILE" --log-level INFO

    print_ok "Snapshot uploaded: $TIMESTAMP"
    prune_remote_versions "$(r_home_snapshots)" "$KEEP_VERSIONS"

    # Prune local staging too
    local local_snaps=()
    mapfile -t local_snaps < <(find "$staging" -mindepth 1 -maxdepth 1 -type d | sort)
    while [[ ${#local_snaps[@]} -gt $KEEP_VERSIONS ]]; do
        rm -rf "${local_snaps[0]}"
        local_snaps=("${local_snaps[@]:1}")
    done
}

# ── Backup: Method B (rclone sync + backup-dir) ───────────────

backup_method_b() {
    print_step "Method B: syncing to Drive (backup-dir for changed/deleted files)..."
    rclone sync "$HOME/" "$(r_home_current)/" \
        --backup-dir "$(r_home_versions)/${TIMESTAMP}" \
        --exclude-from "$EXCLUDE_FILE" \
        --progress \
        --stats-one-line \
        --log-file "$LOG_FILE" --log-level INFO

    print_ok "Home directory synced."
    prune_remote_versions "$(r_home_versions)" "$KEEP_VERSIONS"
}

# ── Backup: Method C (tar archives) ──────────────────────────

backup_method_c() {
    local marker="$PROFILES_DIR/$CURRENT_PROFILE/last_full_backup_marker"

    local do_incremental=false
    if [[ -f "$marker" ]]; then
        print_info "A full backup marker exists ($(stat -c %y "$marker" | cut -d. -f1))."
        ask_yes_no "Create an incremental backup (only files changed since last full)?" && \
            do_incremental=true
    fi

    if [[ "$do_incremental" == "true" ]]; then
        local archive="inc_${TIMESTAMP}.tar.gz"
        print_step "Creating incremental archive: $archive"
        if tar -czf - \
            --exclude-from="$EXCLUDE_FILE" \
            --newer="$marker" \
            -C "$HOME" . | \
            rclone rcat "$(r_home_archives)/$archive" \
            --log-file "$LOG_FILE" --log-level INFO; then
            print_ok "Incremental archive uploaded: $archive"
        else
            print_error "Archive upload failed."
        fi
    else
        local archive="full_${TIMESTAMP}.tar.gz"
        print_step "Creating full archive: $archive"
        if tar -czf - \
            --exclude-from="$EXCLUDE_FILE" \
            -C "$HOME" . | \
            rclone rcat "$(r_home_archives)/$archive" \
            --log-file "$LOG_FILE" --log-level INFO; then
            touch "$marker"
            print_ok "Full archive uploaded: $archive"
        else
            print_error "Archive upload failed."
        fi
    fi

    prune_remote_versions "$(r_home_archives)" "$KEEP_VERSIONS"
}

# ── Backup: System state ──────────────────────────────────────

backup_system_state() {
    [[ "$BACKUP_SYSTEM" != "true" ]] && return
    print_header "Backing Up System State"

    local tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/etc" "$tmp/crontabs" "$tmp/usr-local-bin"

    print_step "Copying /etc (excluding ssl/private)..."
    sudo rsync -a --exclude='ssl/private' /etc/ "$tmp/etc/" 2>/dev/null || \
        print_warn "Some /etc files could not be read."

    print_step "Exporting crontabs..."
    crontab -l > "$tmp/crontabs/user.crontab" 2>/dev/null || true
    sudo crontab -l > "$tmp/crontabs/root.crontab" 2>/dev/null || true

    print_step "Copying /usr/local/bin..."
    rsync -a /usr/local/bin/ "$tmp/usr-local-bin/" 2>/dev/null || true

    rclone sync "$tmp/" "$(r_system)/" \
        --progress --stats-one-line \
        --log-file "$LOG_FILE" --log-level INFO

    rm -rf "$tmp"
    print_ok "System state backed up."
}

# ── Backup: Large directories ─────────────────────────────────

backup_large_dirs() {
    load_separate_large_dirs "$CURRENT_PROFILE"
    [[ ${#SEPARATE_LARGE_DIRS[@]} -eq 0 ]] && return

    print_header "Backing Up Large Directories"
    for dir in "${SEPARATE_LARGE_DIRS[@]}"; do
        [[ -z "$dir" ]] && continue
        [[ -d "$HOME/$dir" ]] || { print_warn "~/$dir not found, skipping."; continue; }
        print_step "Backing up ~/$dir..."
        rclone sync "$HOME/$dir/" "$(r_large_dirs)/$dir/" \
            --progress --stats-one-line \
            --log-file "$LOG_FILE" --log-level INFO
        print_ok "~/$dir backed up."
    done
}

# ── Backup: Packages ──────────────────────────────────────────

backup_packages() {
    print_header "Backing Up Package Lists"
    local tmp
    tmp=$(mktemp -d)
    export_packages "$tmp"
    rclone sync "$tmp/" "$(r_packages)/" \
        --progress --stats-one-line \
        --log-file "$LOG_FILE" --log-level INFO
    rm -rf "$tmp"
    print_ok "Package lists uploaded."
}

# ── Restore: profile selection ────────────────────────────────

select_drive_profile() {
    print_header "Select Backup Profile"
    local profiles=()
    mapfile -t profiles < <(
        rclone lsd "${CRYPT_REMOTE}:profiles/" 2>/dev/null | awk '{print $NF}' | sort
    )

    if [[ ${#profiles[@]} -eq 0 ]]; then
        print_error "No profiles found on Drive. Is the crypt remote configured correctly?"
        exit 1
    fi

    if [[ ${#profiles[@]} -eq 1 ]]; then
        CURRENT_PROFILE="${profiles[0]}"
        print_ok "Using profile: $CURRENT_PROFILE"
        return
    fi

    print_info "Profiles available on Drive:"
    for i in "${!profiles[@]}"; do
        echo -e "  ${BOLD}$((i+1)).${NC} ${profiles[$i]}"
    done
    echo
    local choice
    choice=$(ask_number "Select profile" "1" 1 "${#profiles[@]}")
    CURRENT_PROFILE="${profiles[$((choice-1))]}"
    print_ok "Selected: $CURRENT_PROFILE"
}

# ── Restore: Home — Method B ──────────────────────────────────

restore_home_b() {
    echo -e "  ${BOLD}1.${NC}  Restore latest state (current mirror)"
    echo -e "  ${BOLD}2.${NC}  Restore a specific file or directory from a version"
    echo
    local choice
    choice=$(ask_number "Select" "1" 1 2)

    case "$choice" in
        1)
            print_warn "This overwrites your current home directory with the latest backup."
            ask_yes_no "Continue?" "n" || return
            rclone sync "$(r_home_current)/" "$HOME/" --progress
            print_ok "Home directory restored from current backup."
            ;;
        2)
            print_step "Available versions:"
            local versions=()
            mapfile -t versions < <(
                rclone lsd "$(r_home_versions)/" 2>/dev/null | awk '{print $NF}' | sort -r
            )
            if [[ ${#versions[@]} -eq 0 ]]; then
                print_warn "No versions found. Only the current state is available."
                return
            fi
            for i in "${!versions[@]}"; do
                echo -e "  ${BOLD}$((i+1)).${NC} ${versions[$i]}"
            done
            echo
            local vi
            vi=$(ask_number "Select version" "1" 1 "${#versions[@]}")
            local selected="${versions[$((vi-1))]}"

            local subpath
            subpath=$(ask_value "Path within backup to restore (blank = everything)" "")
            local dest
            dest=$(ask_value "Destination on this machine" "$HOME")
            mkdir -p "$dest"
            rclone copy "$(r_home_versions)/$selected/${subpath}" "$dest/" --progress
            print_ok "Restored from version $selected."
            ;;
    esac
}

# ── Restore: Home — Method A ──────────────────────────────────

restore_home_a() {
    local snapshots=()
    mapfile -t snapshots < <(
        rclone lsd "$(r_home_snapshots)/" 2>/dev/null | awk '{print $NF}' | sort -r
    )
    if [[ ${#snapshots[@]} -eq 0 ]]; then
        print_error "No snapshots found on Drive."
        return
    fi

    print_step "Available snapshots (newest first):"
    for i in "${!snapshots[@]}"; do
        echo -e "  ${BOLD}$((i+1)).${NC} ${snapshots[$i]}"
    done
    echo

    local choice
    choice=$(ask_number "Select snapshot to restore" "1" 1 "${#snapshots[@]}")
    local selected="${snapshots[$((choice-1))]}"

    print_warn "This will overwrite your current home directory with snapshot $selected."
    ask_yes_no "Continue?" "n" || return

    rclone sync "$(r_home_snapshots)/$selected/" "$HOME/" --progress
    print_ok "Snapshot $selected restored."
}

# ── Restore: Home — Method C ──────────────────────────────────

restore_home_c() {
    local archives=()
    mapfile -t archives < <(
        rclone ls "$(r_home_archives)/" 2>/dev/null | awk '{print $NF}' | sort
    )
    if [[ ${#archives[@]} -eq 0 ]]; then
        print_error "No archives found on Drive."
        return
    fi

    local fulls=() incs=()
    for a in "${archives[@]}"; do
        case "$a" in
            full_*) fulls+=("$a") ;;
            inc_*)  incs+=("$a") ;;
        esac
    done

    if [[ ${#fulls[@]} -eq 0 ]]; then
        print_error "No full backup archives found."
        return
    fi

    print_info "Full backups:"
    for i in "${!fulls[@]}"; do
        echo -e "  ${BOLD}$((i+1)).${NC} ${fulls[$i]}"
    done
    echo
    local choice
    choice=$(ask_number "Select full backup to start from" "1" 1 "${#fulls[@]}")
    local selected_full="${fulls[$((choice-1))]}"

    print_warn "This will extract $selected_full into $HOME."
    ask_yes_no "Continue?" "n" || return

    print_step "Downloading and extracting full archive..."
    rclone cat "$(r_home_archives)/$selected_full" | tar -xzf - -C "$HOME"
    print_ok "Full archive extracted."

    # Offer to apply incrementals created after this full
    local full_ts="${selected_full#full_}"; full_ts="${full_ts%.tar.gz}"
    local applicable_incs=()
    for inc in "${incs[@]}"; do
        local inc_ts="${inc#inc_}"; inc_ts="${inc_ts%.tar.gz}"
        [[ "$inc_ts" > "$full_ts" ]] && applicable_incs+=("$inc")
    done

    if [[ ${#applicable_incs[@]} -gt 0 ]]; then
        print_info "Incremental backups created after this full backup:"
        for i in "${!applicable_incs[@]}"; do
            echo -e "  ${BOLD}$((i+1)).${NC} ${applicable_incs[$i]}"
        done
        echo
        if ask_yes_no "Apply incremental backups on top?"; then
            local apply_up_to
            apply_up_to=$(ask_number "Apply up to number" "${#applicable_incs[@]}" 1 "${#applicable_incs[@]}")
            for i in $(seq 0 $(( apply_up_to - 1 ))); do
                print_step "Applying ${applicable_incs[$i]}..."
                rclone cat "$(r_home_archives)/${applicable_incs[$i]}" | tar -xzf - -C "$HOME"
            done
            print_ok "Incremental backups applied."
        fi
    fi
}

# ── Restore: dispatchers ──────────────────────────────────────

restore_home() {
    print_header "Restore Home Directory (Method $BACKUP_METHOD)"
    case "$BACKUP_METHOD" in
        A) restore_home_a ;;
        B) restore_home_b ;;
        C) restore_home_c ;;
    esac
}

restore_system_state() {
    print_header "Restore System State"
    local tmp
    tmp=$(mktemp -d)
    print_step "Downloading system state from Drive..."
    rclone copy "$(r_system)/" "$tmp/" --progress

    if [[ -d "$tmp/etc" ]] && ask_yes_no "Restore /etc from backup?"; then
        sudo rsync -a "$tmp/etc/" /etc/
        print_ok "/etc restored."
    fi

    if [[ -f "$tmp/crontabs/user.crontab" ]] && ask_yes_no "Restore your crontab?"; then
        crontab "$tmp/crontabs/user.crontab"
        print_ok "User crontab restored."
    fi

    if [[ -d "$tmp/usr-local-bin" ]] && ask_yes_no "Restore /usr/local/bin scripts?"; then
        sudo rsync -a "$tmp/usr-local-bin/" /usr/local/bin/
        print_ok "/usr/local/bin restored."
    fi

    rm -rf "$tmp"
}

restore_large_dirs() {
    print_header "Restore Large Directories"
    local dirs=()
    mapfile -t dirs < <(
        rclone lsd "$(r_large_dirs)/" 2>/dev/null | awk '{print $NF}' | sort
    )
    if [[ ${#dirs[@]} -eq 0 ]]; then
        print_warn "No separate large-directory backups found."
        return
    fi
    for dir in "${dirs[@]}"; do
        [[ -z "$dir" ]] && continue
        if ask_yes_no "Restore ~/$dir?"; then
            mkdir -p "$HOME/$dir"
            rclone sync "$(r_large_dirs)/$dir/" "$HOME/$dir/" --progress
            print_ok "~/$dir restored."
        fi
    done
}

restore_packages() {
    print_header "Restore Packages"
    local tmp
    tmp=$(mktemp -d)
    print_step "Downloading package lists from Drive..."
    rclone copy "$(r_packages)/" "$tmp/" --progress
    install_packages "$tmp"
    rm -rf "$tmp"
}

# ── Commands ──────────────────────────────────────────────────

cmd_setup() {
    print_header "gdrive-backup Setup  v${VERSION}"
    print_info "This wizard configures backups for the first time."
    print_info "Run it again any time to reconfigure."
    echo

    check_deps
    load_config   # load any existing values as defaults

    select_or_create_profile
    setup_rclone_drive
    setup_rclone_crypt
    select_backup_method
    setup_versions
    setup_exclusions
    setup_system_backup

    save_config
    save_profile_config "$CURRENT_PROFILE"

    echo
    print_header "Setup Complete"
    local script_name
    script_name=$(basename "$0")
    print_ok "Run ${BOLD}./${script_name} backup${NC}${GREEN}  — create a backup."
    print_ok "Run ${BOLD}./${script_name} restore${NC}${GREEN} — restore from Drive."
    print_ok "Run ${BOLD}./${script_name} status${NC}${GREEN}  — show current config."
}

cmd_backup() {
    load_config
    if [[ -z "${CURRENT_PROFILE:-}" ]]; then
        print_error "Not configured. Run '$(basename "$0") setup' first."
        exit 1
    fi
    load_profile_config "$CURRENT_PROFILE"

    print_header "Backup — Profile: $CURRENT_PROFILE"
    print_info "Method: $BACKUP_METHOD  |  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo

    case "$BACKUP_METHOD" in
        A) backup_method_a ;;
        B) backup_method_b ;;
        C) backup_method_c ;;
    esac

    backup_packages
    backup_system_state
    backup_large_dirs

    print_header "Backup Complete"
    print_ok "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    print_info "Log: $LOG_FILE"
}

cmd_restore() {
    load_config

    if ! rclone listremotes 2>/dev/null | grep -q "^${CRYPT_REMOTE:-gdrive-backup-crypt}:$"; then
        print_error "rclone crypt remote '${CRYPT_REMOTE:-gdrive-backup-crypt}' not found."
        echo
        print_info "If you just reinstalled your OS:"
        print_info "  1. Run '$(basename "$0") setup'"
        print_info "  2. Re-enter the SAME crypt passwords you used originally."
        print_info "  3. Then run '$(basename "$0") restore' again."
        exit 1
    fi

    select_drive_profile
    load_profile_config "$CURRENT_PROFILE"

    print_header "Restore Menu — Profile: $CURRENT_PROFILE"
    echo -e "  ${BOLD}1.${NC}  Home directory"
    echo -e "  ${BOLD}2.${NC}  Packages (apt + Flatpak)"
    echo -e "  ${BOLD}3.${NC}  System state (/etc, crontabs, /usr/local/bin)"
    echo -e "  ${BOLD}4.${NC}  Large directories (backed up separately)"
    echo -e "  ${BOLD}5.${NC}  Everything"
    echo
    local choice
    choice=$(ask_number "Select" "1" 1 5)

    case "$choice" in
        1) restore_home ;;
        2) restore_packages ;;
        3) restore_system_state ;;
        4) restore_large_dirs ;;
        5)
            restore_packages
            restore_home
            restore_system_state
            restore_large_dirs
            ;;
    esac
}

cmd_status() {
    load_config
    print_header "gdrive-backup Status"
    print_info "Version:         ${VERSION}"
    print_info "Profile:         ${CURRENT_PROFILE:-${RED}not set${NC}}"
    print_info "Backup method:   ${BACKUP_METHOD:-${RED}not set${NC}}"
    print_info "Keep versions:   ${KEEP_VERSIONS}"
    print_info "System backup:   ${BACKUP_SYSTEM}"
    print_info "Drive remote:    ${GDRIVE_REMOTE}"
    print_info "Crypt remote:    ${CRYPT_REMOTE}"
    print_info "Config dir:      $CONFIG_DIR"
    echo

    if rclone listremotes 2>/dev/null | grep -q "^${CRYPT_REMOTE}:$"; then
        print_ok "Crypt remote is configured."
    else
        print_warn "Crypt remote is NOT configured. Run 'setup'."
    fi

    if rclone listremotes 2>/dev/null | grep -q "^${GDRIVE_REMOTE}:$"; then
        print_ok "Google Drive remote is configured."
    else
        print_warn "Google Drive remote is NOT configured. Run 'setup'."
    fi

    echo
    if [[ -f "$LOG_FILE" ]]; then
        print_info "Last 10 log lines:"
        tail -10 "$LOG_FILE"
    else
        print_dim "No log file yet."
    fi
}

cmd_help() {
    cat <<EOF

${BOLD}gdrive-backup${NC} v${VERSION} — encrypted Google Drive backup for Linux

${BOLD}USAGE${NC}
  $(basename "$0") <command>

${BOLD}COMMANDS${NC}
  ${BOLD}setup${NC}      First-time configuration wizard (re-run to reconfigure)
  ${BOLD}backup${NC}     Run a backup for the current profile
  ${BOLD}restore${NC}    Interactively restore files, packages, or system state
  ${BOLD}status${NC}     Show configuration and last log entries
  ${BOLD}help${NC}       Show this message

${BOLD}FIRST-TIME SETUP${NC}
  ./$(basename "$0") setup
  ./$(basename "$0") backup

${BOLD}AFTER OS REINSTALL${NC}
  # 1. Re-run setup (use the SAME crypt passwords as before)
  ./$(basename "$0") setup
  # 2. Restore everything
  ./$(basename "$0") restore

${BOLD}FILES${NC}
  Config:   $CONFIG_FILE
  Profiles: $PROFILES_DIR/
  Excludes: $EXCLUDE_FILE
  Log:      $LOG_FILE

EOF
}

# ── Entry point ───────────────────────────────────────────────

main() {
    case "${1:-help}" in
        setup)          cmd_setup ;;
        backup)         cmd_backup ;;
        restore)        cmd_restore ;;
        status)         cmd_status ;;
        help|--help|-h) cmd_help ;;
        *)
            print_error "Unknown command: $1"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
