#!/usr/bin/env bash
# =============================================================================
#  sf-rom-upload.sh  v1.2
#
#  Interactive, arrow-key driven uploader for SourceForge File Releases (FRS).
#  Designed for pushing ROM zips / any release file to your own SourceForge
#  project, from any folder on your PC, laptop or phone (Termux).
#
#  Flow:
#    1. asks for SourceForge username, password, then verifies the login
#    2. reads the project list off your SourceForge account and lets you pick
#       one, add another by name, or create one
#    3. inside the project: create a folder, create a file, upload a file,
#       open a folder, go up a level
#    4. inside a folder: browse your local disk and upload the ROM
#    5. after each upload: upload another file, or go back / exit
#
#  Navigation: UP / DOWN arrows + Enter, everywhere. Fallbacks: k / j / q.
#
#  The password is typed at most once per run: the script opens a single
#  authenticated connection and every upload, listing and folder action
#  reuses it. 'Set up password-free login (SSH key)' in the project menu
#  makes it never ask at all.
#
#  Requirements
#    required : sftp  (openssh-client)
#    optional : sshpass  -> asks for the password once instead of every step
#               rsync    -> resumable uploads, used automatically for >100 MB
#
#    Termux (Android) : pkg install openssh sshpass rsync
#    Debian / Ubuntu : sudo apt install openssh-client sshpass rsync
#    Fedora           : sudo dnf install openssh-clients sshpass rsync
#    macOS            : brew install hudochenkov/sshpass/sshpass rsync
#    Windows          : use WSL, or Git Bash + an sshpass build
#
#  Notes
#    - Nothing is written to disk except your username, project list and last
#      local folder (~/.config/sf-rom-uploader/). The password is never saved.
#    - Files over 10 GB are not mirrored by SourceForge and cannot be
#      downloaded, so keep releases under that.
#    - Uploaded files show up on the project Files page after a few minutes.
#
#  Usage:  ./sf-rom-upload.sh [--help]
# =============================================================================

# --- no set -e on purpose: menus use arithmetic and non-zero statuses --------

APP_NAME="sf-rom-upload"
APP_VERSION="1.2"
SF_HOST="frs.sourceforge.net"
SF_PORT=22
FRS_ROOT="/home/frs/project"
FRS_ROOT_ALT="/home/pfs/project"   # legacy layout, used only as a fallback
BIG_FILE_BYTES=$((100 * 1024 * 1024))

# --- colours -----------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR-} ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_REV=$'\033[7m'
    C_CY=$'\033[36m'; C_GR=$'\033[32m'; C_RD=$'\033[31m'; C_YL=$'\033[33m'
else
    C_RST=''; C_B=''; C_DIM=''; C_REV=''; C_CY=''; C_GR=''; C_RD=''; C_YL=''
fi

# --- state -------------------------------------------------------------------
SF_USER=""
SF_PASS=""
SF_TARGET=""
SF_PROJECT=""
REMOTE_ROOT=""
REMOTE_CWD=""
SF_LAST_OUT=""
LOCAL_FILE=""
MENU_SEL=0
KEY=""
REPLY=""
HAVE_SSHPASS=0
HAVE_RSYNC=0
LAST_USER=""
LAST_LOCAL_DIR=""
MASTER_OK=0            # is the shared ssh connection up?
SF_KEY=""              # optional private key file (password-free login)
KNOWN_PROJECTS=()      # projects opened before, remembered on this machine
API_PROJECTS=()        # project unix names reported by SourceForge
API_NAMES=()           # their display names
API_SUMMARIES=()       # their one-line descriptions

TMPBASE="${TMPDIR:-/tmp}"
CTL_SOCK="$TMPBASE/sfrom-$$.sock"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sf-rom-uploader"
CFG_USER="$CFG_DIR/user"
CFG_PROJECTS="$CFG_DIR/projects"
CFG_LASTDIR="$CFG_DIR/lastdir"
CFG_REMOTE="$CFG_DIR/remote-projects"
CFG_KEY="$CFG_DIR/key"

SF_OPTS=()

# All ssh/sftp calls share one connection, so the password is typed once.
build_sf_opts() {
    SF_OPTS=(
        -o BatchMode=no
        -o StrictHostKeyChecking=accept-new
        -o ControlMaster=auto
        -o "ControlPath=$CTL_SOCK"
        -o ControlPersist=1800
        -o ConnectTimeout=25
        -o ServerAliveInterval=30
        -o "Port=$SF_PORT"
    )
    if [[ -n $SF_KEY && -f $SF_KEY ]]; then
        SF_OPTS+=(-i "$SF_KEY" -o IdentitiesOnly=yes)
    fi
}

# =============================================================================
#  terminal modes
# =============================================================================
# bash's `read -n1` flips the terminal into raw mode for each keypress and
# restores it afterwards, so the script only needs to make sure the terminal
# is handed back sane when it exits.
TTY_SAVED=""

tty_raw() {
    [[ -n $TTY_SAVED ]] || TTY_SAVED="$(stty -g 2>/dev/null)"
    # non-canonical, no echo, one byte at a time. Ctrl-C still signals.
    stty -icanon -echo min 1 time 0 2>/dev/null
}

tty_restore() {
    [[ -n $TTY_SAVED ]] && stty "$TTY_SAVED" 2>/dev/null
    TTY_SAVED=""
}

# Reads one line in raw mode. $1 = "echo" to show the typed characters.
# Works whether the terminal sends CR (Termux, most terminals) or LF.
read_line() {
    local show="${1-}" ch
    REPLY=""
    while true; do
        if ! IFS= read -rsn1 ch; then
            REPLY=""
            return 1
        fi
        case $ch in
            $'\r'|$'\n'|'')
                break
                ;;
            $'\177'|$'\b')
                if [[ -n $REPLY ]]; then
                    REPLY="${REPLY%?}"
                    [[ -n $show ]] && printf '\b \b'
                fi
                ;;
            $'\004')
                [[ -z $REPLY ]] && return 1
                break
                ;;
            $'\003')
                return 1
                ;;
            *)
                REPLY="$REPLY$ch"
                [[ -n $show ]] && printf '%s' "$ch"
                ;;
        esac
    done
    return 0
}

# =============================================================================
#  small output helpers
# =============================================================================
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n'   "$C_GR" "$C_RST" "$*"; }
info() { printf '%s[..]%s %s\n'   "$C_CY" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n'    "$C_YL" "$C_RST" "$*"; }
err()  { printf '%s[x]%s %s\n'    "$C_RD" "$C_RST" "$*" >&2; }

clear_screen() { printf '\033[H\033[2J'; }

press_enter() {
    printf '%sPress Enter to continue...%s' "$C_DIM" "$C_RST"
    read_line
    printf '\n'
}

die() { err "$*"; exit 1; }

# human readable byte size
human() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i]
    }'
}

local_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || wc -c <"$1" | tr -d ' '
}

# =============================================================================
#  small utilities
# =============================================================================
term_cols() {
    local c=""
    if command -v tput >/dev/null 2>&1; then
        c="$(tput cols 2>/dev/null)"
    fi
    if [[ -z $c || ! $c =~ ^[0-9]+$ ]]; then
        c="$(stty size 2>/dev/null | awk '{print $2}')"
    fi
    [[ -z $c || ! $c =~ ^[0-9]+$ || $c -lt 20 ]] && c=80
    printf '%s' "$c"
}

# cut a line down so it can never wrap and break the menu redraw
fit_text() {
    local s="$1" max="${2:-70}"
    if (( ${#s} > max )); then
        printf '%s...' "${s:0:$((max - 3))}"
    else
        printf '%s' "$s"
    fi
}

in_list() {  # needle, then the list
    local needle="$1" x
    shift
    for x in "$@"; do
        [[ $x == "$needle" ]] && return 0
    done
    return 1
}

http_get() {  # url -> body on stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 -A "sf-rom-upload/$APP_VERSION" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O - "$1"
    else
        return 127
    fi
}

# =============================================================================
#  reading the project list from SourceForge
# =============================================================================
# SourceForge publishes a user's projects as JSON at /rest/u/<user>/profile :
#   {"username": "...", "projects": [{"name": "EN-OS", "url": "/p/en-os/",
#    "summary": "...", "last_updated": "..."}], "skills": [...]}
# No login needed, and no jq or python either - it is parsed with sed/grep.
fetch_sf_projects() {
    API_PROJECTS=()
    API_NAMES=()
    API_SUMMARIES=()

    local url="https://sourceforge.net/rest/u/$SF_USER/profile"
    local json slice obj name u short summary

    json="$(http_get "$url" 2>/dev/null)"
    local rc=$?
    if (( rc == 127 )); then
        SF_FETCH_MSG="curl or wget is not installed"
        return 1
    fi
    if (( rc != 0 )) || [[ -z $json ]]; then
        SF_FETCH_MSG="could not reach sourceforge.net"
        return 1
    fi
    if [[ $json != *'"projects"'* ]]; then
        SF_FETCH_MSG="the reply did not look like a profile"
        return 1
    fi

    # keep only the contents of the "projects" array
    slice="$(printf '%s' "$json" | tr -d '\n\r' |
        sed -n 's/.*"projects"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')"

    # each entry is a flat {...} object
    while IFS= read -r obj; do
        [[ -z $obj ]] && continue
        u="$(printf '%s' "$obj" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [[ $u == /p/*/ ]] || continue
        short="${u#/p/}"
        short="${short%/}"
        [[ -z $short ]] && continue
        name="$(printf '%s' "$obj" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        summary="$(printf '%s' "$obj" | sed -n 's/.*"summary"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [[ -z $name ]] && name="$short"
        API_PROJECTS+=("$short")
        API_NAMES+=("$name")
        API_SUMMARIES+=("$summary")
    done < <(printf '%s' "$slice" | grep -o '{[^{}]*}')
    return 0
}

cfg_save_remote_projects() {
    local i
    mkdir -p "$CFG_DIR" 2>/dev/null
    : >"$CFG_REMOTE" 2>/dev/null
    for i in "${!API_PROJECTS[@]}"; do
        printf '%s\t%s\t%s\n' "${API_PROJECTS[i]}" "${API_NAMES[i]}" "${API_SUMMARIES[i]}" \
            >>"$CFG_REMOTE" 2>/dev/null
    done
}

cfg_load_remote_projects() {
    API_PROJECTS=()
    API_NAMES=()
    API_SUMMARIES=()
    [[ -f $CFG_REMOTE ]] || return 1
    local a b c
    while IFS=$'\t' read -r a b c; do
        [[ -z $a ]] && continue
        API_PROJECTS+=("$a")
        API_NAMES+=("${b:-$a}")
        API_SUMMARIES+=("$c")
    done <"$CFG_REMOTE"
    (( ${#API_PROJECTS[@]} > 0 ))
}

# fetch + cache; falls back to the cached copy when offline
load_project_list() {
    local loud="${1:-0}"

    if [[ -n ${SF_NO_FETCH-} ]]; then
        cfg_load_remote_projects
        (( loud )) && info "SF_NO_FETCH is set - keeping the saved list."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        cfg_load_remote_projects
        if (( loud )); then
            warn "curl/wget is not installed, so the list cannot be fetched."
            warn "Termux: pkg install curl    Debian: sudo apt install curl"
        fi
        return 1
    fi

    info "Reading your project list from SourceForge ..."
    if fetch_sf_projects; then
        cfg_save_remote_projects
        if (( ${#API_PROJECTS[@]} == 0 )); then
            ok "SourceForge reports no projects on this account yet."
        else
            ok "${#API_PROJECTS[@]} project(s) found."
        fi
        return 0
    fi

    cfg_load_remote_projects
    if (( loud )); then
        warn "Could not fetch the list: ${SF_FETCH_MSG:-unknown reason}"
        warn "Showing the projects saved on this machine instead."
    fi
    return 1
}

# =============================================================================
#  key reader + arrow-key menu
# =============================================================================
# Sets KEY to one of: up down enter quit esc left right <char>
read_key() {
    KEY=""
    local k c1 c2

    if ! IFS= read -rsn1 k; then
        KEY=quit
        return 0
    fi

    case $k in
        $'\033')
            # read the rest of the escape sequence one byte at a time, so a
            # terminal that dribbles the bytes out still decodes correctly
            c1=""
            if ! IFS= read -rsn1 -t 0.4 c1; then
                KEY=esc
                return 0
            fi
            case $c1 in
                '['|'O')
                    c2=""
                    if ! IFS= read -rsn1 -t 0.4 c2; then
                        KEY=esc
                        return 0
                    fi
                    case $c2 in
                        A) KEY=up ;;
                        B) KEY=down ;;
                        C) KEY=right ;;
                        D) KEY=left ;;
                        *) KEY=esc ;;
                    esac
                    ;;
                *) KEY=esc ;;
            esac
            ;;
        ''|$'\r'|$'\n')
            # a terminal in raw mode sends CR for Enter, not LF
            KEY=enter ;;
        k|K)
            KEY=up ;;
        j|J)
            KEY=down ;;
        q|Q)
            KEY=quit ;;
        *)
            KEY="$k" ;;
    esac
}

# menu "Title" "subtitle (may be multi-line)" "item 1" "item 2" ...
# Returns 0 and sets MENU_SEL on select, 1 on quit.
menu() {
    local title="$1" subtitle="${2-}"
    shift 2
    local -a items=("$@")
    local n=${#items[@]}
    local sel=0 i first=1

    # a wrapped line would break the redraw, so keep every item on one line
    local width=$(( $(term_cols) - 8 ))
    (( width < 20 )) && width=20
    for ((i = 0; i < n; i++)); do
        items[i]="$(fit_text "${items[i]}" "$width")"
    done

    if (( n == 0 )); then
        warn "Nothing to show here."
        return 1
    fi

    clear_screen
    printf '%s%s%s\n' "$C_B$C_CY" "$title" "$C_RST"
    if [[ -n $subtitle ]]; then
        local line
        while IFS= read -r line; do
            printf '%s%s%s\n' "$C_DIM" "$line" "$C_RST"
        done <<<"$subtitle"
    fi
    local rule
    rule="$(printf '%*s' "$(( $(term_cols) - 2 ))" '' | tr ' ' '-')"
    printf '%s%s%s\n' "$C_DIM" "$rule" "$C_RST"

    while true; do
        if (( first )); then
            first=0
        else
            printf '\033[%dA' "$((n + 1))"
        fi

        for ((i = 0; i < n; i++)); do
            if (( i == sel )); then
                printf '\033[K%s  %s %s\n' "$C_REV" "${items[i]}" "$C_RST"
            else
                printf '\033[K    %s\n' "${items[i]}"
            fi
        done
        printf '\033[K%s  UP/DOWN move - Enter select - q quit%s\n' "$C_DIM" "$C_RST"

        read_key

        case $KEY in
            up)    sel=$(( (sel - 1 + n) % n )) ;;
            down)  sel=$(( (sel + 1) % n )) ;;
            enter) MENU_SEL=$sel; return 0 ;;
            quit)  MENU_SEL=-1; return 1 ;;
            *)     : ;;
        esac
    done
}

# =============================================================================
#  text prompts
# =============================================================================
ask() {  # ask "label" ["default"]  -> REPLY
    local label="$1" def="${2-}"
    if [[ -n $def ]]; then
        printf '%s%s%s [%s]: ' "$C_B" "$label" "$C_RST" "$def"
    else
        printf '%s%s%s: ' "$C_B" "$label" "$C_RST"
    fi
    read_line echo
    printf '\n'
    if [[ -z $REPLY && -n $def ]]; then
        REPLY="$def"
    fi
}

ask_secret() {  # ask_secret "label" -> REPLY
    printf '%s%s%s: ' "$C_B" "$1" "$C_RST"
    read_line
    printf '\n'
}

confirm() {  # confirm "question" -> 0 yes / 1 no
    local ans
    printf '%s%s%s [y/N]: ' "$C_B" "$1" "$C_RST"
    read_line echo
    printf '\n'
    ans="$REPLY"
    case $ans in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# =============================================================================
#  config (username, known projects, last local folder)
# =============================================================================
cfg_load() {
    mkdir -p "$CFG_DIR" 2>/dev/null
    [[ -f $CFG_USER ]] && LAST_USER="$(<"$CFG_USER")"
    [[ -f $CFG_LASTDIR ]] && LAST_LOCAL_DIR="$(<"$CFG_LASTDIR")"
    [[ -f $CFG_KEY ]] && SF_KEY="$(<"$CFG_KEY")"
    KNOWN_PROJECTS=()
    if [[ -f $CFG_PROJECTS ]]; then
        local p
        while IFS= read -r p; do
            [[ -n $p ]] && KNOWN_PROJECTS+=("$p")
        done <"$CFG_PROJECTS"
    fi
    return 0
}

cfg_save_user() {
    mkdir -p "$CFG_DIR" 2>/dev/null
    printf '%s\n' "$1" >"$CFG_USER" 2>/dev/null
}

cfg_save_dir() {
    mkdir -p "$CFG_DIR" 2>/dev/null
    printf '%s\n' "$1" >"$CFG_LASTDIR" 2>/dev/null
}

cfg_save_key() {
    mkdir -p "$CFG_DIR" 2>/dev/null
    if [[ -n ${1-} ]]; then
        printf '%s\n' "$1" >"$CFG_KEY" 2>/dev/null
    else
        rm -f "$CFG_KEY" 2>/dev/null
    fi
}

cfg_add_project() {
    local p="$1" x found=0
    for x in "${KNOWN_PROJECTS[@]-}"; do
        [[ $x == "$p" ]] && found=1
    done
    (( found )) && return 0
    KNOWN_PROJECTS+=("$p")
    mkdir -p "$CFG_DIR" 2>/dev/null
    printf '%s\n' "${KNOWN_PROJECTS[@]}" >"$CFG_PROJECTS" 2>/dev/null
}

# =============================================================================
#  one shared connection (so the password is asked once)
# =============================================================================
open_master() {
    MASTER_OK=0
    [[ -n $SF_TARGET ]] || return 1

    # already have a live master socket?
    if ssh -o "ControlPath=$CTL_SOCK" -O check "$SF_TARGET" >/dev/null 2>&1; then
        MASTER_OK=1
        return 0
    fi

    local -a cmd=(ssh -M -N -f)
    cmd+=(-o "ControlPath=$CTL_SOCK")
    cmd+=(-o ControlMaster=yes)
    cmd+=(-o ControlPersist=1800)
    cmd+=(-o BatchMode=no)
    cmd+=(-o StrictHostKeyChecking=accept-new)
    cmd+=(-o ConnectTimeout=25)
    cmd+=(-o "Port=$SF_PORT")
    if [[ -n $SF_KEY && -f $SF_KEY ]]; then
        cmd+=(-i "$SF_KEY" -o IdentitiesOnly=yes)
    fi
    cmd+=("$SF_TARGET")

    # ssh needs a normal terminal for its own password prompt
    tty_restore
    if (( HAVE_SSHPASS )) && [[ -n $SF_PASS ]]; then
        SSHPASS="$SF_PASS" sshpass -e "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
    tty_raw

    if ssh -o "ControlPath=$CTL_SOCK" -O check "$SF_TARGET" >/dev/null 2>&1; then
        MASTER_OK=1
        return 0
    fi
    return 1
}

close_master() {
    [[ -n $SF_TARGET ]] || return 0
    ssh -o "ControlPath=$CTL_SOCK" -O exit "$SF_TARGET" >/dev/null 2>&1
    rm -f "$CTL_SOCK" 2>/dev/null
    MASTER_OK=0
}

# =============================================================================
#  sftp plumbing
# =============================================================================
# sf_run [-q] <<< "sftp batch commands"   (host/opts are filled in for you)
sf_run() {
    local quiet=0 batch rc
    if [[ ${1-} == -q ]]; then
        quiet=1
        shift
    fi

    batch="$(mktemp "$TMPBASE/sfrom-batch.XXXXXX")" || {
        err "could not create a temp file in $TMPBASE"
        return 1
    }
    cat >"$batch"

    local -a cmd=(sftp "${SF_OPTS[@]}")
    (( quiet )) && cmd+=(-q)
    cmd+=(-b "$batch" "$SF_TARGET")

    if (( HAVE_SSHPASS )) && [[ -n $SF_PASS ]]; then
        # -e reads the password from $SSHPASS, so it never shows up in `ps`
        SSHPASS="$SF_PASS" sshpass -e "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
    rc=$?

    rm -f "$batch"
    return $rc
}

sf_check_auth() {
    SF_LAST_OUT="$(printf 'pwd\n' | sf_run -q 2>&1)"
    return $?
}

sf_check_path() {
    local path="$1"
    SF_LAST_OUT="$(printf 'cd "%s"\npwd\n' "$path" | sf_run -q 2>&1)"
    return $?
}

# fills SF_DIRS / SF_FILES for a remote directory
SF_DIRS=()
SF_FILES=()
sf_entries() {
    local path="$1" out line t name
    SF_DIRS=()
    SF_FILES=()

    out="$(printf 'ls -l "%s"\n' "$path" | sf_run -q 2>/dev/null)"
    if [[ -z $out ]]; then
        # either an empty folder or an unreadable one - ask the server which
        sf_check_path "$path" && return 0
        return 1
    fi

    while IFS= read -r line; do
        [[ -z $line || $line == total* ]] && continue
        t="${line:0:1}"
        case $t in
            d|-)
                name="$(printf '%s\n' "$line" | awk '{for(i=9;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}')"
                [[ -z $name || $name == . || $name == .. ]] && continue
                if [[ $t == d ]]; then
                    SF_DIRS+=("$name")
                else
                    SF_FILES+=("$name")
                fi
                ;;
        esac
    done <<<"$out"
    return 0
}

sf_mkdir() {
    printf 'mkdir "%s"\n' "$1" | sf_run -q 2>&1
}

sf_exists() {  # remote path
    printf 'ls "%s"\n' "$1" | sf_run -q >/dev/null 2>&1
}

sf_remote_size() {  # remote file -> bytes on stdout
    local out
    out="$(printf 'ls -l "%s"\n' "$1" | sf_run -q 2>/dev/null)"
    printf '%s\n' "$out" | awk 'NR==1{print $5}'
}

# upload one local file into a remote directory (sftp)
sf_put() {
    local lfile="$1" rdir="$2" base
    base="$(basename "$lfile")"
    printf 'cd "%s"\nput "%s" "%s"\n' "$rdir" "$lfile" "$base" | sf_run
}

# upload one local file into a remote directory (rsync, resumable)
rsync_put() {
    local lfile="$1" rdir="$2"
    local -a e=(ssh "${SF_OPTS[@]}")
    if (( HAVE_SSHPASS )) && [[ -n $SF_PASS ]]; then
        SSHPASS="$SF_PASS" rsync -av --partial --progress -e "${e[*]}" \
            "$lfile" "$SF_TARGET:$rdir/"
    else
        rsync -av --partial --progress -e "${e[*]}" "$lfile" "$SF_TARGET:$rdir/"
    fi
}

# make an empty file on the server
sf_touch() {  # remote dir, filename
    local rdir="$1" name="$2" tmp rc
    tmp="$(mktemp "$TMPBASE/sfrom-empty.XXXXXX")" || return 1
    printf 'cd "%s"\nput "%s" "%s"\n' "$rdir" "$tmp" "$name" | sf_run -q
    rc=$?
    rm -f "$tmp"
    return $rc
}

# SourceForge allows only these characters in file and folder names:
#   -_ +.,=#~@!()[] a-zA-Z0-9   (space included)
# Returns whatever is left over after removing the allowed ones - empty is good.
bad_name_chars() {
    printf '%s' "$1" | tr -d 'A-Za-z0-9 _+.,=#~@!()[]-'
}

classify_sf_error() {
    case "$SF_LAST_OUT" in
        *"Permission denied (publickey"*|*"Permission denied (password"*|*"Authentication failed"*|*"Too many authentication failures"*)
            printf 'auth\n' ;;
        *"No such file or directory"*|*"not found"*)
            printf 'nopath\n' ;;
        *"Permission denied"*)
            printf 'noperm\n' ;;
        *"Connection refused"*|*"Connection timed out"*|*"Could not resolve hostname"*|*"Network is unreachable"*)
            printf 'network\n' ;;
        *)
            printf 'other\n' ;;
    esac
}

# =============================================================================
#  local file browser
# =============================================================================
pick_local_file() {
    local dir="${1:-$HOME}"
    [[ -d $dir ]] || dir="$HOME"

    while true; do
        local -a items=() paths=()
        local -a ds=() fs=()
        local x count=0

        items+=("[ .. ]  go up one folder")
        paths+=("$(dirname "$dir")")
        items+=("[ path ] type a folder or file path")
        paths+=("__PATH__")

        shopt -s nullglob
        for x in "$dir"/*/; do ds+=("${x%/}"); done
        for x in "$dir"/*; do [[ -f $x ]] && fs+=("$x"); done
        shopt -u nullglob

        for x in "${ds[@]}"; do
            (( count >= 200 )) && break
            items+=("$(basename "$x")/")
            paths+=("$x")
            count=$((count + 1))
        done
        for x in "${fs[@]}"; do
            (( count >= 200 )) && break
            items+=("$(basename "$x")")
            paths+=("$x")
            count=$((count + 1))
        done

        local sub="$dir"
        if (( count >= 200 )); then
            sub="$dir"$'\n'"showing the first 200 entries only"
        fi

        if ! menu "Choose the file to upload" "$sub" "${items[@]}"; then
            return 1
        fi

        local p="${paths[$MENU_SEL]}"

        if [[ $p == "__PATH__" ]]; then
            ask "Full path" "$dir"
            p="${REPLY/#\~/$HOME}"
            [[ -z $p ]] && continue
        fi

        if [[ -d $p ]]; then
            dir="$p"
            continue
        fi
        if [[ -f $p ]]; then
            LOCAL_FILE="$p"
            LAST_LOCAL_DIR="$dir"
            cfg_save_dir "$dir"
            return 0
        fi
        err "Not a file: $p"
        sleep 1
    done
}

# =============================================================================
#  upload flow
# =============================================================================
do_upload() {  # remote dir
    local rdir="$1"
    local lfile rname answer method bytes

    if ! pick_local_file "${LAST_LOCAL_DIR:-$HOME}"; then
        return 1
    fi
    lfile="$LOCAL_FILE"

    if [[ $lfile == *'"'* ]]; then
        err 'The file path contains a double quote, which sftp cannot handle. Rename it first.'
        return 1
    fi

    rname="$(basename "$lfile")"
    ask "Remote file name" "$rname"
    rname="$REPLY"
    [[ -z $rname ]] && rname="$(basename "$lfile")"

    local badn
    badn="$(bad_name_chars "$rname")"
    if [[ -n $badn ]]; then
        err "SourceForge does not allow these characters in a name: $badn"
        say "Rename the file, or type a different remote name."
        press_enter
        return 1
    fi

    bytes="$(local_size "$lfile")"
    [[ -z $bytes ]] && bytes=0

    clear_screen
    say "Local file : $lfile"
    say "Size       : $(human "$bytes")"
    say "Destination: $rdir/$rname"
    say ""

    if (( bytes > 10737418240 )); then
        warn "That file is over 10 GB. SourceForge will accept it but will not"
        warn "mirror it, so nobody can download it. Split or shrink it first."
        if ! confirm "Upload it anyway?"; then
            return 1
        fi
    fi

    if sf_exists "$rdir/$rname"; then
        warn "A file with that name already exists on the server."
        if ! confirm "Overwrite it?"; then
            info "Upload cancelled."
            press_enter
            return 1
        fi
    fi

    method="sftp"
    if (( HAVE_RSYNC )) && (( bytes > BIG_FILE_BYTES )); then
        method="rsync"
    fi
    case "${SF_UPLOAD_METHOD-}" in
        sftp|rsync) method="$SF_UPLOAD_METHOD" ;;
    esac

    info "Uploading with $method - keep this window open."
    if [[ $method == sftp ]] && (( bytes > BIG_FILE_BYTES )); then
        say "${C_DIM}sftp may not draw a progress bar here; a big ROM can take a while."
        say "Install rsync for a progress bar and resumable transfers.${C_RST}"
    fi
    say ""

    if [[ $method == rsync ]]; then
        rsync_put "$lfile" "$rdir"
        answer=$?
    else
        sf_put "$lfile" "$rdir"
        answer=$?
    fi

    say ""
    if (( answer != 0 )); then
        err "Upload failed (exit code $answer)."
        say ""
        say "Things worth checking:"
        say "  - the file is still under 10 GB (SourceForge's mirror limit)"
        say "  - you have 'release technician' or admin rights on the project"
        say "  - your connection stayed up; rsync can resume a half-sent file"
        press_enter
        return 1
    fi

    local rsize
    rsize="$(sf_remote_size "$rdir/$rname")"
    if [[ -n $rsize && $rsize =~ ^[0-9]+$ ]]; then
        if (( rsize == bytes )); then
            ok "Uploaded and verified: $rname ($(human "$rsize"))"
        else
            warn "Uploaded, but the server reports $(human "$rsize") instead of $(human "$bytes")."
        fi
    else
        ok "Uploaded: $rname"
    fi
    say "It usually appears on the project Files page within a few minutes."
    return 0
}

# =============================================================================
#  remote folder browser
# =============================================================================
remote_listing_block() {  # remote dir -> multi-line string on stdout
    local dir="$1" d f n=0 max=12
    if ! sf_entries "$dir"; then
        printf '  (could not read this folder)\n'
        return 1
    fi
    if (( ${#SF_DIRS[@]} == 0 && ${#SF_FILES[@]} == 0 )); then
        printf '  (empty)\n'
        return 0
    fi
    for d in "${SF_DIRS[@]}"; do
        (( n >= max )) && { printf '  ...\n'; return 0; }
        printf '  [dir ] %s/\n' "$d"
        n=$((n + 1))
    done
    for f in "${SF_FILES[@]}"; do
        (( n >= max )) && { printf '  ...\n'; return 0; }
        printf '  [file] %s\n' "$f"
        n=$((n + 1))
    done
    return 0
}

browse_folder() {
    local listing sub

    while true; do
        listing="$(remote_listing_block "$REMOTE_CWD")"
        sub="$REMOTE_CWD"$'\n'"$listing"

        local -a items=()
        items+=("Upload a file (ROM) into this folder")
        items+=("Create a new folder here")
        items+=("Create an empty file here")
        items+=("Open a folder")
        items+=("Refresh listing")
        if [[ $REMOTE_CWD != "$REMOTE_ROOT" ]]; then
            items+=("Up one level")
        fi
        items+=("Back to project list")
        items+=("Exit")

        if ! menu "Project: $SF_PROJECT" "$sub" "${items[@]}"; then
            cleanup_exit 0
        fi

        local pick="${items[$MENU_SEL]}"
        case "$pick" in
            "Upload a file (ROM) into this folder")
                upload_loop "$REMOTE_CWD"
                ;;
            "Create a new folder here")
                ask "New folder name"
                local fname="$REPLY"
                if [[ -z $fname ]]; then
                    info "Nothing entered."
                    sleep 1
                    continue
                fi
                local bad
                bad="$(bad_name_chars "$fname")"
                if [[ -n $bad ]]; then
                    err "SourceForge does not allow these characters: $bad"
                    say "Allowed: letters, digits, space and -_+.,=#~@!()[]"
                    press_enter
                    continue
                fi
                local out
                out="$(sf_mkdir "$REMOTE_CWD/$fname")"
                if sf_exists "$REMOTE_CWD/$fname"; then
                    ok "Folder created: $fname"
                    REMOTE_CWD="$REMOTE_CWD/$fname"
                else
                    err "Could not create the folder."
                    [[ -n $out ]] && say "$out"
                    press_enter
                fi
                ;;
            "Create an empty file here")
                ask "New file name" "readme.txt"
                local nfile="$REPLY"
                if [[ -z $nfile ]]; then
                    info "Nothing entered."
                    sleep 1
                    continue
                fi
                local badf
                badf="$(bad_name_chars "$nfile")"
                if [[ -n $badf ]]; then
                    err "SourceForge does not allow these characters: $badf"
                    press_enter
                    continue
                fi
                if sf_touch "$REMOTE_CWD" "$nfile"; then
                    ok "Empty file created: $nfile"
                else
                    err "Could not create the file."
                fi
                press_enter
                ;;
            "Open a folder")
                if pick_remote_folder "$REMOTE_CWD"; then
                    REMOTE_CWD="$PICKED_REMOTE_DIR"
                fi
                ;;
            "Refresh listing")
                continue
                ;;
            "Up one level")
                local parent
                parent="$(dirname "$REMOTE_CWD")"
                if [[ $parent == "$REMOTE_ROOT" || $parent == "$REMOTE_ROOT"/* ]]; then
                    REMOTE_CWD="$parent"
                else
                    REMOTE_CWD="$REMOTE_ROOT"
                fi
                ;;
            "Back to project list")
                return 0
                ;;
            "Exit")
                cleanup_exit 0
                ;;
        esac
    done
}

# Picks a sub-folder. The menu prints to the screen, so the result comes back
# in PICKED_REMOTE_DIR - capturing stdout would swallow the whole menu.
PICKED_REMOTE_DIR=""
pick_remote_folder() {  # remote dir -> 0 and PICKED_REMOTE_DIR set
    local dir="$1"
    while true; do
        if ! sf_entries "$dir"; then
            err "Could not read $dir"
            press_enter
            return 1
        fi

        local -a items=() paths=()
        local sub
        sub="$dir"
        if [[ $dir != "$REMOTE_ROOT" ]]; then
            items+=("[ .. ]  up one level")
            paths+=("$(dirname "$dir")")
        fi
        items+=("[ cancel ]")
        paths+=("__CANCEL__")

        local d
        for d in "${SF_DIRS[@]}"; do
            items+=("$d/")
            paths+=("$dir/$d")
        done

        if (( ${#SF_DIRS[@]} == 0 )); then
            sub="$dir"$'\n'"no sub-folders here - use 'Create a new folder here' first"
        fi

        if ! menu "Open a folder" "$sub" "${items[@]}"; then
            return 1
        fi

        local p="${paths[$MENU_SEL]}"
        [[ $p == "__CANCEL__" ]] && return 1
        PICKED_REMOTE_DIR="$p"
        return 0
    done
}

upload_loop() {  # remote dir
    local rdir="$1"

    while true; do
        if ! do_upload "$rdir"; then
            # picker cancelled, or the transfer failed and the user was told why
            return 0
        fi

        local -a items=(
            "Upload another file to this folder"
            "Choose a different local folder and upload"
            "Back to the folder menu"
            "Exit"
        )
        if ! menu "Upload finished" "$rdir" "${items[@]}"; then
            cleanup_exit 0
        fi
        case "${items[$MENU_SEL]}" in
            "Upload another file to this folder")
                continue
                ;;
            "Choose a different local folder and upload")
                LAST_LOCAL_DIR="$HOME"
                continue
                ;;
            "Back to the folder menu")
                return 0
                ;;
            "Exit")
                cleanup_exit 0
                ;;
        esac
    done
}

# =============================================================================
#  project selection
# =============================================================================
resolve_remote_root() {  # project unix name -> 0 ok, REMOTE_ROOT set
    local p="$1" cand
    for cand in "$FRS_ROOT/$p" "$FRS_ROOT_ALT/$p"; do
        if sf_check_path "$cand"; then
            REMOTE_ROOT="$cand"
            return 0
        fi
        case "$(classify_sf_error)" in
            auth)    return 2 ;;
            network) return 3 ;;
        esac
    done
    return 1
}

open_project() {  # project unix name
    local p="$1" rc

    clear_screen
    info "Connecting to $SF_HOST ..."

    resolve_remote_root "$p"
    rc=$?

    if (( rc == 2 )); then
        err "Login failed: $SF_USER"
        say ""
        say "$SF_LAST_OUT"
        say ""
        say "If you turned on two-factor authentication on SourceForge, password"
        say "login over SSH is blocked - add an SSH key in your SourceForge"
        say "account settings (Account -> SSH Settings) instead."
        press_enter
        return 1
    fi

    if (( rc == 3 )); then
        err "Network problem reaching $SF_HOST."
        say "$SF_LAST_OUT"
        press_enter
        return 1
    fi

    if (( rc != 0 )); then
        err "Could not open project '$p'."
        say ""
        say "The folder $FRS_ROOT/$p was not reachable. Common causes:"
        say "  - the project's UNIX name is different from its display name"
        say "    (it is always lowercase - check the project URL)"
        say "  - the project was created minutes ago and the file space is"
        say "    still being set up; try again a little later"
        say "  - your account is not an admin of that project"
        say ""
        say "$SF_LAST_OUT"
        press_enter
        return 1
    fi

    SF_PROJECT="$p"
    REMOTE_CWD="$REMOTE_ROOT"
    cfg_add_project "$p"
    ok "Opened $p  ($REMOTE_ROOT)"
    sleep 0.6
    browse_folder
    return 0
}

setup_ssh_key() {
    clear_screen
    say "${C_B}Password-free login (SSH key)${C_RST}"
    say ""
    say "SourceForge accepts an SSH public key instead of a password."
    say "Do this once and this uploader never asks for a password again."
    say ""

    local key="${SF_KEY:-$HOME/.ssh/id_ed25519_sf}"

    if [[ -f $key ]]; then
        ok "Key already on this machine: $key"
    else
        if ! command -v ssh-keygen >/dev/null 2>&1; then
            err "ssh-keygen is not installed - it comes with openssh-client."
            say "Termux: pkg install openssh"
            press_enter
            return 1
        fi
        mkdir -p "$(dirname "$key")" 2>/dev/null
        chmod 700 "$(dirname "$key")" 2>/dev/null
        info "Creating a new key (no passphrase, so the script can use it)..."
        if ! ssh-keygen -t ed25519 -N "" -C "$SF_USER for sourceforge" -f "$key" >/dev/null 2>&1; then
            err "Could not create the key at $key"
            press_enter
            return 1
        fi
        chmod 600 "$key" 2>/dev/null
        ok "Created $key"
        say "${C_DIM}Keep the private key private - only the .pub file goes to SourceForge.${C_RST}"
    fi

    say ""
    say "${C_B}Your public key - copy this whole line:${C_RST}"
    say ""
    if [[ -f "$key.pub" ]]; then
        sed 's/^/    /' "$key.pub"
    else
        err "No public key found at $key.pub"
        press_enter
        return 1
    fi
    say ""
    say "Paste it here:  ${C_CY}https://sourceforge.net/auth/shell_services${C_RST}"
    say "  (log in -> SSH Public Keys -> paste -> save)"
    say "It usually works within a minute or two."
    say ""
    if confirm "Open that page in your browser now?"; then
        open_url "https://sourceforge.net/auth/shell_services" ||
            info "Could not open a browser - use the address above."
    fi

    SF_KEY="$key"
    cfg_save_key "$key"
    build_sf_opts
    say ""
    if confirm "Try a key-only login now?"; then
        SF_PASS=""
        close_master
        clear_screen
        info "Connecting with the key ..."
        if open_master && sf_check_auth; then
            ok "It works - no more password prompts."
            press_enter
            return 0
        fi
        err "The key is not accepted yet."
        say "Give SourceForge a few minutes, then try again."
        say "Until then, run the uploader and type your password when asked."
        press_enter
        return 1
    fi
    return 0
}

create_project_help() {
    clear_screen
    say "${C_B}Create a new SourceForge project${C_RST}"
    say ""
    say "SourceForge does not let scripts create projects - it is a web form"
    say "with a review step - so open this page and fill it in:"
    say ""
    say "    ${C_CY}https://sourceforge.net/create/${C_RST}"
    say ""
    say "While filling the form, note the ${C_B}UNIX name${C_RST}: it is lowercase,"
    say "becomes part of the URL, and is the folder name the uploads go into."
    say ""
    say "When the project exists, come back here and use"
    say "'Add an existing project by name'."
    say ""
    if confirm "Open the page in your browser now?"; then
        open_url "https://sourceforge.net/create/" ||
            info "Could not open a browser - use the address above."
    fi
    press_enter
}

add_project_by_name() {
    clear_screen
    say "${C_B}Add an existing project${C_RST}"
    say ""
    say "Enter the project's UNIX name (the lowercase name in its URL,"
    say "e.g. for sourceforge.net/projects/myrom/  ->  myrom)"
    say ""
    ask "Project UNIX name"
    local p
    p="$(printf '%s' "$REPLY" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    if [[ -z $p ]]; then
        info "Nothing entered."
        sleep 1
        return 1
    fi
    open_project "$p"
}

project_menu() {
    while true; do
        local -a items=() vals=()
        local p i label

        # 1. what SourceForge says this account has
        for i in "${!API_PROJECTS[@]}"; do
            label="${API_NAMES[i]}  [${API_PROJECTS[i]}]"
            if [[ -n ${API_SUMMARIES[i]} ]]; then
                label="$label  - ${API_SUMMARIES[i]}"
            fi
            items+=("$label")
            vals+=("open:${API_PROJECTS[i]}")
        done

        # 2. projects opened before, in case the list could not be fetched
        for p in "${KNOWN_PROJECTS[@]-}"; do
            [[ -z $p ]] && continue
            in_list "$p" "${API_PROJECTS[@]-}" && continue
            items+=("$p  [saved]")
            vals+=("open:$p")
        done

        items+=("Refresh the project list from SourceForge")
        vals+=("refresh")
        items+=("Add an existing project by name")
        vals+=("add")
        items+=("Create a new project on SourceForge")
        vals+=("create")
        items+=("Set up password-free login (SSH key)")
        vals+=("sshkey")
        items+=("Change SourceForge account")
        vals+=("relogin")
        items+=("Exit")
        vals+=("exit")

        local sub="Signed in as $SF_USER on $SF_HOST"
        if (( ${#API_PROJECTS[@]} > 0 )); then
            sub="$sub"$'\n'"Your projects on SourceForge (${#API_PROJECTS[@]}):"
        elif (( ${#KNOWN_PROJECTS[@]} > 0 )); then
            sub="$sub"$'\n'"Projects saved on this machine (list not fetched):"
        else
            sub="$sub"$'\n'"No projects found on this account yet."
        fi

        if ! menu "SourceForge ROM uploader" "$sub" "${items[@]}"; then
            cleanup_exit 0
        fi

        case "${vals[$MENU_SEL]}" in
            open:*)
                open_project "${vals[$MENU_SEL]#open:}"
                ;;
            refresh)
                load_project_list 1
                sleep 1
                ;;
            sshkey)
                setup_ssh_key
                ;;
            add)
                add_project_by_name
                ;;
            create)
                create_project_help
                ;;
            relogin)
                return 1
                ;;
            exit)
                cleanup_exit 0
                ;;
        esac
    done
}

# =============================================================================
#  login + dependency checks
# =============================================================================
check_deps() {
    if ! command -v sftp >/dev/null 2>&1; then
        err "sftp is not installed."
        say ""
        say "Termux : pkg install openssh"
        say "Debian : sudo apt install openssh-client"
        say "Fedora : sudo dnf install openssh-clients"
        say "macOS  : ships with macOS (or: brew install openssh)"
        exit 1
    fi

    command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1
    command -v rsync   >/dev/null 2>&1 && HAVE_RSYNC=1
}

login_flow() {
    clear_screen
    say "${C_B}Sign in to SourceForge${C_RST}"
    say ""

    if [[ -n ${SF_USERNAME-} ]]; then
        SF_USER="$SF_USERNAME"
        say "Username: $SF_USER (from \$SF_USERNAME)"
    else
        ask "SourceForge username" "$LAST_USER"
        SF_USER="$(printf '%s' "$REPLY" | tr -d '[:space:]')"
    fi

    if [[ -z $SF_USER ]]; then
        err "A username is required."
        return 1
    fi
    cfg_save_user "$SF_USER"

    SF_TARGET="$SF_USER@$SF_HOST"

    say ""
    if [[ -n $SF_KEY && -f $SF_KEY ]]; then
        # a key is set up, so no password at all
        SF_PASS=""
        ok "Using your SSH key: $SF_KEY"
        say "${C_DIM}No password needed. 'Set up password-free login' can replace the key.${C_RST}"
    else
        if (( HAVE_SSHPASS )); then
            ask_secret "Password (hidden)"
            SF_PASS="$REPLY"
            say "${C_DIM}Asked once - every step after this reuses the connection.${C_RST}"
        else
            say "${C_YL}sshpass is not installed${C_RST}, but the password is only"
            say "needed once: the script keeps one connection open and reuses it."
            say "${C_DIM}Termux: pkg install sshpass  makes even that one prompt silent.${C_RST}"
            say "Leave it empty to use an SSH key instead."
            say ""
            ask_secret "Password (hidden, empty = use SSH key)"
            SF_PASS="$REPLY"
        fi
    fi

    build_sf_opts

    clear_screen
    info "Opening one connection to $SF_HOST ..."
    if open_master; then
        ok "Connected - the password will not be asked again in this session."
    elif [[ -n $SF_KEY && -f $SF_KEY ]]; then
        : # the key signs each connection in silently, so nothing to warn about
    else
        warn "Could not hold the connection open."
        warn "If ssh keeps asking for the password, install sshpass, or use"
        warn "'Set up password-free login (SSH key)' from the project menu."
    fi
    say ""
    info "Checking login ..."
    if sf_check_auth; then
        ok "Signed in as $SF_USER"
        sleep 0.5
        return 0
    fi

    case "$(classify_sf_error)" in
        network)
            err "Cannot reach $SF_HOST."
            say "$SF_LAST_OUT"
            ;;
        *)
            err "Login failed."
            say ""
            say "$SF_LAST_OUT"
            say ""
            say "Notes:"
            say "  - SourceForge needs your login name, not your email"
            say "  - with 2FA enabled, or if the password is refused, use the"
            say "    'Set up password-free login (SSH key)' option"
            say "    (page: https://sourceforge.net/auth/shell_services)"
            ;;
    esac
    press_enter
    return 1
}

# =============================================================================
#  lifecycle
# =============================================================================
cleanup_exit() {
    local code="${1:-0}"
    tty_restore
    # close the shared ssh connection, if one is open
    close_master
    printf '%s\n' ""
    printf '%sBye.%s\n' "$C_DIM" "$C_RST"
    exit "$code"
}

open_url() {  # open a web page if the machine can
    local url="$1" opener=""
    if [[ -n ${TERMUX_VERSION-} ]] && command -v termux-open-url >/dev/null 2>&1; then
        opener="termux-open-url"
    elif command -v xdg-open >/dev/null 2>&1; then
        opener="xdg-open"
    elif command -v open >/dev/null 2>&1; then
        opener="open"
    fi
    [[ -n $opener ]] || return 1
    "$opener" "$url" >/dev/null 2>&1 &
    return 0
}

banner() {
    clear_screen
    printf '%s\n' "${C_B}${C_CY}  SourceForge ROM uploader  v$APP_VERSION${C_RST}"
    printf '%s\n' "${C_DIM}  arrow keys + Enter to navigate${C_RST}"
    printf '\n'
    if [[ -n ${TERMUX_VERSION-} ]]; then
        printf '%s\n' "${C_DIM}  Termux detected - use the arrow keys on the extra keys row.${C_RST}"
    fi
}

usage() {
    cat <<EOF
$APP_NAME v$APP_VERSION - interactive ROM uploader for SourceForge

Usage:
  ./sf-rom-upload.sh          start the interactive menu
  ./sf-rom-upload.sh --help   show this text

Environment:
  SF_USERNAME        skip the username prompt
  SF_UPLOAD_METHOD   force "sftp" or "rsync"
  SF_NO_FETCH        skip reading the project list from sourceforge.net
  NO_COLOR           disable colours
  TMPDIR             where the temporary ssh socket goes

Config is kept in: $CFG_DIR
Password is never written to disk.

Requirements: sftp (required), curl or wget (for the project list),
              sshpass (recommended), rsync (optional).
  Termux: pkg install openssh curl sshpass rsync
EOF
}

main() {
    case "${1-}" in
        -h|--help|help)
            usage
            exit 0
            ;;
        -v|--version)
            printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
            exit 0
            ;;
    esac

    trap 'cleanup_exit 130' INT TERM

    check_deps
    cfg_load

    if [[ ! -t 0 ]]; then
        die "This needs an interactive terminal (arrow keys). Run it directly, not through a pipe."
    fi

    tty_raw
    trap 'tty_restore' EXIT
    banner

    while true; do
        if login_flow; then
            load_project_list 0
            project_menu
            # project_menu returns 1 only when the user asked to change account
        else
            if ! confirm "Try again?"; then
                cleanup_exit 1
            fi
        fi
    done
}

# run only when executed, so the file can be sourced for testing
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
