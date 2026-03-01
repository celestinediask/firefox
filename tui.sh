#!/usr/bin/env bash
# firefox-debloat-tui.sh — Terminal UI for debloat-firefox.sh
# Navigate: ↑ ↓ / k j   Activate: Enter / Space / mouse click

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBLOAT="$SCRIPT_DIR/debloat-firefox.sh"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\e[1m';     DIM=$'\e[2m';      RESET=$'\e[0m'
    RED=$'\e[31m';     GREEN=$'\e[32m';   YELLOW=$'\e[33m'
    BLUE=$'\e[34m'
    WHITE=$'\e[97m';   BG_WHITE=$'\e[107m'; BLACK=$'\e[30m'
    HIDE=$'\e[?25l';   SHOW=$'\e[?25h'
    CLR=$'\e[2J\e[H'
    MOUSE_ON=$'\e[?1000h\e[?1003h\e[?1006h'   # enable click + motion reporting (SGR)
    MOUSE_OFF=$'\e[?1006l\e[?1003l\e[?1000l'  # disable on exit
else
    BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW=''
    BLUE='' WHITE='' BG_WHITE='' BLACK=''
    HIDE='' SHOW='' CLR='' MOUSE_ON='' MOUSE_OFF=''
fi

# ---------------------------------------------------------------------------
# Menu items
# ---------------------------------------------------------------------------
LABELS=(
    "Debloat Firefox"
    "Clear User Data"
    "Restore Factory Settings"
    "Restart Firefox"
    "Quit"
)
DESCS=(
    "Disable telemetry, Pocket, sponsored content,\n     address-bar suggestions, HTTPS-only mode and more."
    "Delete ~/.mozilla and ~/.cache/mozilla.\n     All profiles, history and cookies are wiped."
    "Remove all debloat files and wipe user data.\n     Firefox starts completely fresh on next launch."
    "Close all Firefox windows and relaunch the browser.\n     Useful to apply profile changes immediately."
    "Exit this program.\n"
)

# ---------------------------------------------------------------------------
# Layout constants — must match draw_menu() exactly
# HEADER_ROWS : lines printed before the first item
# ITEM_ROWS   : lines per item (label + desc_lines + blank)
# ---------------------------------------------------------------------------
HEADER_ROWS=5   # \n + hr + title + hr + \n
ITEM_ROWS=4     # label(1) + desc(2) + blank(1)   — all items use \n in desc
# ITEM_START_ROWS[i] is computed once by compute_item_rows()
declare -a ITEM_START_ROWS

compute_item_rows() {
    local row=$(( HEADER_ROWS + 1 ))
    local i
    for (( i=0; i<${#LABELS[@]}; i++ )); do
        ITEM_START_ROWS[$i]=$row
        (( row += ITEM_ROWS ))
    done
}

# Return the item index (0-based) whose area contains terminal row $1,
# or -1 if the row does not belong to any item.
row_to_item() {
    local click_row=$1
    local i
    for (( i=0; i<${#LABELS[@]}; i++ )); do
        local s=${ITEM_START_ROWS[$i]}
        # clickable zone: label + 2 desc lines (rows s … s+2), blank excluded
        if (( click_row >= s && click_row <= s + 2 )); then
            printf '%d' $i; return
        fi
    done
    printf '%d' -1
}

# ---------------------------------------------------------------------------
# Key / mouse reader
# Sets global KEY to the raw byte sequence.
# Using a global avoids command-substitution stripping trailing newlines,
# which would silently swallow the Enter key (\n) when ICRNL is active.
# ---------------------------------------------------------------------------
KEY=''
read_key() {
    KEY=''
    local ch
    IFS= read -r -s -n1 KEY
    if [[ $KEY == $'\x1b' ]]; then
        # Read the escape sequence one byte at a time, stopping at the first
        # letter.  All CSI sequences (arrow keys, SGR mouse) end with a letter
        # (A-Z / a-z), so this returns the moment the sequence is complete
        # rather than waiting for a fixed byte-count or a 50 ms timeout.
        while IFS= read -r -s -n1 -t 0.05 ch 2>/dev/null; do
            KEY+="$ch"
            [[ $ch =~ [A-Za-z] ]] && break
        done
    fi
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
WIDTH=54

hr() {
    local ch="${1:-─}" line="  "
    for (( i=0; i<WIDTH; i++ )); do line+="$ch"; done
    printf '%s\n' "$line"
}

draw_menu() {
    local sel=$1 hov=${2:--1}
    printf '%s' "$CLR"
    printf '\n'
    printf '%s' "${BOLD}${BLUE}"; hr; printf '  Firefox Debloat\n'; hr
    printf '%s\n' "$RESET"

    local i
    for (( i=0; i<${#LABELS[@]}; i++ )); do

        if (( i == sel )); then
            printf '  %s%s%s[ %s ]%s\n' "$BG_WHITE" "$BOLD" "$BLACK" "${LABELS[$i]}" "$RESET"
        elif (( i == hov )); then
            printf '  %s%s[ %s ]%s\n'   "$BOLD" "$WHITE"             "${LABELS[$i]}" "$RESET"
        else
            printf '  %s[ %s ]%s\n'     "$DIM"                       "${LABELS[$i]}" "$RESET"
        fi
        printf '     %s' "$DIM"
        printf "${DESCS[$i]}"
        printf '%s\n' "$RESET"
        printf '\n'
    done

    printf '%s' "$DIM"; hr; printf '%s' "$RESET"
    printf '  %s↑ ↓  navigate    Enter / click  run    q  quit%s\n' "$DIM" "$RESET"
}

# Update a single item's label row in-place (cursor-position, no screen clear).
# Used for hover changes so only the two affected rows are touched.
draw_item() {
    local i=$1 sel=$2 hov=$3

    printf '\e[%d;1H\e[2K' "${ITEM_START_ROWS[$i]}"
    if (( i == sel )); then
        printf '  %s%s%s[ %s ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "${LABELS[$i]}" "$RESET"
    elif (( i == hov )); then
        printf '  %s%s[ %s ]%s'   "$BOLD" "$WHITE"             "${LABELS[$i]}" "$RESET"
    else
        printf '  %s[ %s ]%s'     "$DIM"                       "${LABELS[$i]}" "$RESET"
    fi
}

# ---------------------------------------------------------------------------
# Output helpers (used inside actions while cursor is visible)
# ---------------------------------------------------------------------------
clr()   { printf '%s' "$CLR"; }
info()  { printf '  %s[INFO]%s  %s\n'  "$GREEN"  "$RESET" "$*"; }
warn()  { printf '  %s[WARN]%s  %s\n'  "$YELLOW" "$RESET" "$*"; }
step()  { printf '\n  %s%s==> %s%s\n\n' "$BOLD" "$BLUE" "$*" "$RESET"; }
ok()    { printf '\n  %s%s✓  %s%s\n'   "$GREEN" "$BOLD" "$*" "$RESET"; }

# Drain all pending bytes from stdin (leftover mouse press/release events).
# Uses a 0.15 s timeout so multi-byte SGR sequences are fully consumed.
drain_input() {
    while IFS= read -r -s -n1 -t 0.15 _ 2>/dev/null; do :; done
}

pause() {
    local sel=0 hover=-1   # 0=Back to Menu  1=Quit
    local n=2
    local last_sel=-1 last_hover=-1

    # Print separator + two buttons + hint line.
    # Layout (relative to cursor position on entry):
    #   +0  blank
    #   +1  separator hr
    #   +2  Back to Menu   ← btn_back
    #   +3  blank
    #   +4  Quit           ← btn_quit
    #   +5  blank
    #   +6  hint           ← cursor stays here; we query CPR to get this row
    printf '\n'
    printf '%s' "$DIM"; hr; printf '%s' "$RESET"
    printf '  %s%s%s[ Back to Menu ]%s\n' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
    printf '\n'
    printf '  %s[ Quit ]%s\n'             "$DIM"                         "$RESET"
    printf '\n'
    printf '  %s↑ ↓  navigate    Enter / click  select    b  menu    q  quit%s' "$DIM" "$RESET"

    # Query current cursor row via ANSI CPR (\e[6n → terminal replies \e[row;colR).
    # This lets us map mouse-click row numbers back to the buttons above.
    local _hint_row=0
    drain_input   # clear any stray bytes before reading the CPR response
    printf '\e[6n'
    local _cpr=''
    IFS= read -r -s -d 'R' -t 1 _cpr 2>/dev/null && {
        _cpr="${_cpr##*\[}"          # strip leading escape / [
        _hint_row="${_cpr%%;*}"      # keep only the row number
    }
    local btn_back=$(( _hint_row - 4 ))
    local btn_quit=$(( _hint_row - 2 ))

    printf '%s%s' "$HIDE" "$MOUSE_ON"

    while true; do
        if (( sel != last_sel )); then
            printf '\e[%d;1H\e[2K' "$btn_back"
            if (( sel == 0 )); then
                printf '  %s%s%s[ Back to Menu ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 0 )); then
                printf '  %s%s[ Back to Menu ]%s'   "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ Back to Menu ]%s'      "$DIM"                      "$RESET"
            fi
            printf '\e[%d;1H\e[2K' "$btn_quit"
            if (( sel == 1 )); then
                printf '  %s%s%s[ Quit ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 1 )); then
                printf '  %s%s[ Quit ]%s'   "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ Quit ]%s'      "$DIM"                      "$RESET"
            fi
            last_sel=$sel
            last_hover=$hover
        elif (( hover != last_hover )); then
            if ! IFS= read -r -s -n0 -t 0 2>/dev/null; then
                printf '\e[%d;1H\e[2K' "$btn_back"
                if (( sel == 0 )); then
                    printf '  %s%s%s[ Back to Menu ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
                elif (( hover == 0 )); then
                    printf '  %s%s[ Back to Menu ]%s'   "$BOLD"     "$WHITE"         "$RESET"
                else
                    printf '  %s[ Back to Menu ]%s'      "$DIM"                      "$RESET"
                fi
                printf '\e[%d;1H\e[2K' "$btn_quit"
                if (( sel == 1 )); then
                    printf '  %s%s%s[ Quit ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
                elif (( hover == 1 )); then
                    printf '  %s%s[ Quit ]%s'   "$BOLD"     "$WHITE"         "$RESET"
                else
                    printf '  %s[ Quit ]%s'      "$DIM"                      "$RESET"
                fi
                last_hover=$hover
            fi
        fi

        read_key

        case "$KEY" in
            $'\e[A' | k | K)  (( sel = (sel - 1 + n) % n )); hover=-1 ;;
            $'\e[B' | j | J)  (( sel = (sel + 1) % n ));     hover=-1 ;;
            $'\r' | $'\n' | ' ')
                printf '%s' "$MOUSE_OFF"; drain_input
                (( sel == 1 )) && exit 0
                return 0
                ;;
            b | B)  printf '%s' "$MOUSE_OFF"; drain_input; return 0 ;;
            q | Q)  printf '%s' "$MOUSE_OFF"; drain_input; exit 0    ;;
        esac

        if [[ $KEY == $'\e[<'* ]]; then
            local inner="${KEY:3}"
            local etype="${inner: -1}"
            inner="${inner%[Mm]}"
            local btn col row
            IFS=';' read -r btn col row <<< "$inner"
            case "$etype/$btn" in
                M/0)
                    if   (( row == btn_back )); then
                        printf '%s' "$MOUSE_OFF"; drain_input; return 0
                    elif (( row == btn_quit )); then
                        printf '%s' "$MOUSE_OFF"; drain_input; exit 0
                    fi
                    ;;
                M/35)
                    if   (( row == btn_back )); then hover=0
                    elif (( row == btn_quit )); then hover=1
                    else hover=-1
                    fi
                    ;;
                M/64)  (( sel = (sel - 1 + n) % n )); hover=-1 ;;
                M/65)  (( sel = (sel + 1) % n ));     hover=-1 ;;
            esac
        fi
    done
}

confirm() {
    local msg=$1
    local sel=1 hover=-1   # default: No (safer); hover is visual-only
    local n=2

    printf '%s' "$MOUSE_ON"

    # Fixed layout after CLR:
    #   row 1 — blank
    #   row 2 — warning message
    #   row 3 — blank
    #   row 4 — Yes
    #   row 5 — blank  (gap to prevent accidental clicks)
    #   row 6 — No

    local last_sel=-1 last_hover=-1
    while true; do
        if (( sel != last_sel )); then
            # Full redraw (selection changed)
            printf '%s' "$CLR"
            printf '\n'
            printf '  %s%s! %s%s\n' "$YELLOW" "$BOLD" "$msg" "$RESET"
            printf '\n'
            if (( sel == 0 )); then
                printf '  %s%s%s[ Yes ]%s\n' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 0 )); then
                printf '  %s%s[ Yes ]%s\n'   "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ Yes ]%s\n'      "$DIM"                      "$RESET"
            fi
            printf '\n'
            if (( sel == 1 )); then
                printf '  %s%s%s[ No ]%s\n'  "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 1 )); then
                printf '  %s%s[ No ]%s\n'    "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ No ]%s\n'       "$DIM"                      "$RESET"
            fi
            printf '\n'
            printf '  %s↑ ↓  navigate    Enter / click  confirm    q  cancel%s\n' "$DIM" "$RESET"
            last_sel=$sel
            last_hover=$hover
        elif (( hover != last_hover )); then
            # Partial in-place update — only redraw the two button rows
            printf '\e[4;1H\e[2K'
            if (( sel == 0 )); then
                printf '  %s%s%s[ Yes ]%s' "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 0 )); then
                printf '  %s%s[ Yes ]%s'   "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ Yes ]%s'      "$DIM"                      "$RESET"
            fi
            printf '\e[6;1H\e[2K'
            if (( sel == 1 )); then
                printf '  %s%s%s[ No ]%s'  "$BG_WHITE" "$BOLD" "$BLACK" "$RESET"
            elif (( hover == 1 )); then
                printf '  %s%s[ No ]%s'    "$BOLD"     "$WHITE"         "$RESET"
            else
                printf '  %s[ No ]%s'       "$DIM"                      "$RESET"
            fi
            last_hover=$hover
        fi

        read_key

        case "$KEY" in
            $'\e[A' | k | K)  (( sel = (sel - 1 + n) % n )); hover=-1 ;;
            $'\e[B' | j | J)  (( sel = (sel + 1) % n ));     hover=-1 ;;
            $'\r' | $'\n' | ' ')
                printf '%s' "$MOUSE_OFF"; drain_input
                return $(( sel ))   # 0=Yes(success)  1=No(failure)
                ;;
            y | Y)          printf '%s' "$MOUSE_OFF"; drain_input; return 0 ;;
            q | Q | n | N)  printf '%s' "$MOUSE_OFF"; drain_input; return 1 ;;
        esac

        if [[ $KEY == $'\e[<'* ]]; then
            local inner="${KEY:3}"
            local etype="${inner: -1}"
            inner="${inner%[Mm]}"
            local btn col row
            IFS=';' read -r btn col row <<< "$inner"
            case "$etype/$btn" in
                M/0)
                    if (( row == 4 )); then      # Yes row — click
                        printf '%s' "$MOUSE_OFF"; drain_input; return 0
                    elif (( row == 6 )); then    # No row — click
                        printf '%s' "$MOUSE_OFF"; drain_input; return 1
                    fi
                    ;;
                M/35)                            # hover — visual only, no sel change
                    if   (( row == 4 )); then hover=0
                    elif (( row == 6 )); then hover=1
                    else hover=-1
                    fi
                    ;;
                M/64)  (( sel = (sel - 1 + n) % n )); hover=-1 ;;
                M/65)  (( sel = (sel + 1) % n ));     hover=-1 ;;
            esac
        fi
    done
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_debloat() {
    clr
    step "Debloating Firefox"
    printf '  %sStep 1/2 — system-wide settings (may prompt for sudo)%s\n\n' "$DIM" "$RESET"
    sudo bash "$DEBLOAT" --system-only
    printf '\n  %sStep 2/2 — user.js to existing profiles%s\n\n' "$DIM" "$RESET"
    bash "$DEBLOAT" --user-only
    ok "Debloat complete.  Restart Firefox for settings to take effect."
}

do_clear() {
    clr
    confirm "This permanently deletes ~/.mozilla and ~/.cache/mozilla." || return
    step "Clearing Firefox user data"
    for path in "$HOME/.mozilla" "$HOME/.cache/mozilla"; do
        if [[ -e "$path" ]]; then
            rm -rf -- "$path" && info "Removed $path"
        else
            info "$path — not found (already clean)"
        fi
    done
    ok "User data cleared."
}

do_restore() {
    clr
    confirm "This removes all debloat files and wipes ~/.mozilla." || return

    step "Removing system debloat files"
    local sys_files=(
        "/usr/lib/firefox-esr/defaults/pref/debloat.js"
        "/usr/lib/firefox/defaults/pref/debloat.js"
        "/etc/firefox/policies/policies.json"
        "/usr/lib/firefox-esr/distribution/policies.json"
        "/usr/lib/firefox/distribution/policies.json"
        "/snap/firefox/current/usr/lib/firefox/distribution/policies.json"
    )
    local found=false
    for f in "${sys_files[@]}"; do
        [[ -f "$f" ]] || continue
        sudo rm -f -- "$f" && info "Removed $f" && found=true
    done
    $found || info "No system debloat files found"

    step "Removing user.js from profiles"
    local found_js=false
    while IFS= read -r js; do
        rm -f -- "$js" && info "Removed $js" && found_js=true
    done < <(find "$HOME/.mozilla/firefox" -maxdepth 2 -name "user.js" 2>/dev/null)
    $found_js || info "No profile user.js files found"

    step "Clearing user data"
    for path in "$HOME/.mozilla" "$HOME/.cache/mozilla"; do
        [[ -e "$path" ]] && rm -rf -- "$path" && info "Removed $path" || info "$path — not found"
    done

    local manifest="$HOME/.local/share/debloat-firefox/manifest"
    if [[ -f "$manifest" ]]; then
        rm -f -- "$manifest"
        rmdir --ignore-fail-on-non-empty "$(dirname "$manifest")" 2>/dev/null || true
        info "Removed manifest"
    fi

    ok "Factory reset complete.  Firefox will start fresh on next launch."
}

do_restart() {
    clr
    confirm "This will close all Firefox windows and relaunch." || return

    step "Stopping Firefox"
    local killed=false
    pkill -x firefox-esr 2>/dev/null && { killed=true; info "Sent stop signal to firefox-esr"; }
    pkill -x firefox     2>/dev/null && { killed=true; info "Sent stop signal to firefox";     }
    $killed || info "No running Firefox instance found"

    # Wait up to 5 s for processes to exit, then force-kill
    local waited=0
    while pgrep -x firefox-esr &>/dev/null || pgrep -x firefox &>/dev/null; do
        sleep 0.5
        (( ++waited ))
        if (( waited >= 10 )); then
            warn "Firefox did not exit cleanly; force-killing..."
            pkill -9 -x firefox-esr 2>/dev/null || true
            pkill -9 -x firefox     2>/dev/null || true
            sleep 0.5
            break
        fi
    done

    step "Launching Firefox"
    local ff_bin=''
    for ff_bin in firefox-esr firefox; do
        command -v "$ff_bin" &>/dev/null && break
        ff_bin=''
    done
    if [[ -z $ff_bin ]]; then
        warn "Could not find firefox or firefox-esr in PATH."
        return 1
    fi

    nohup "$ff_bin" &>/dev/null &
    disown
    ok "Firefox relaunched ($ff_bin)."
}

# ---------------------------------------------------------------------------
# Activate the item at index $1 (show cursor, run action, pause, hide cursor)
# Mouse is disabled for the entire action so clicks don't echo junk to screen.
# ---------------------------------------------------------------------------
activate() {
    local item=$1
    printf '%s%s' "$SHOW" "$MOUSE_OFF"
    drain_input   # discard any events buffered before mouse was turned off
    case $item in
        0) do_debloat; pause ;;
        1) do_clear   && pause ;;
        2) do_restore && pause ;;
        3) do_restart && pause ;;
        4) printf '%s' "$CLR"; exit 0 ;;
    esac
    printf '%s%s' "$HIDE" "$MOUSE_ON"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
    if [[ ! -f "$DEBLOAT" ]]; then
        printf '%sError:%s debloat-firefox.sh not found at %s\n' \
            "$RED" "$RESET" "$DEBLOAT" >&2
        exit 1
    fi

    compute_item_rows

    local sel=0 hover=-1
    local n=${#LABELS[@]}

    # Disable terminal echo for the duration of the TUI.
    # read -s toggles echo per-call; with byte-by-byte reading the brief
    # windows between calls can let mouse-event bytes get echoed.
    # Saving/restoring via stty -g keeps it off continuously.
    local _saved_stty
    _saved_stty=$(stty -g 2>/dev/null) || _saved_stty=''
    [[ -n $_saved_stty ]] && stty -echo 2>/dev/null

    # On any exit: restore terminal, disable mouse, drain events, restore cursor
    trap '[[ -n $_saved_stty ]] && stty "$_saved_stty" 2>/dev/null
          printf "%s%s" "$MOUSE_OFF" "$CLR"
          drain_input
          printf "%s" "$SHOW"' EXIT INT TERM

    printf '%s%s' "$HIDE" "$MOUSE_ON"

    local last_sel=-1 last_hover=-1
    while true; do
        if (( sel != last_sel )); then
            # Selection changed — full redraw
            draw_menu "$sel" "$hover"
            last_sel=$sel
            last_hover=$hover
        elif (( hover != last_hover )); then
            # Only hover changed — skip draw if more input is already buffered
            # (read -n0 -t0 returns 0 when input is available, without consuming).
            # This debounces rapid motion events to the final resting position.
            if ! IFS= read -r -s -n0 -t 0 2>/dev/null; then
                (( last_hover >= 0 )) && draw_item "$last_hover" "$sel" "$hover"
                (( hover      >= 0 )) && draw_item "$hover"      "$sel" "$hover"
                last_hover=$hover
            fi
        fi
        read_key

        # ── arrow keys / vim keys ──────────────────────────────────────────
        case "$KEY" in
            $'\e[A' | k | K)   (( sel = (sel - 1 + n) % n )); hover=-1  ; continue ;;
            $'\e[B' | j | J)   (( sel = (sel + 1) % n ));     hover=-1  ; continue ;;
            $'\r' | $'\n' | ' ')
                activate "$sel"
                last_sel=-1
                last_hover=-1
                hover=-1
                continue
                ;;
            q | Q)  printf '%s%s%s' "$SHOW" "$MOUSE_OFF" "$CLR" ; exit 0   ;;
        esac

        # ── SGR mouse events  \e[<btn;col;rowM (press) / m (release) ──────
        if [[ $KEY == $'\e[<'* ]]; then
            # Strip \e[<  and trailing M/m
            local inner="${KEY:3}"
            local etype="${inner: -1}"   # M = press, m = release
            inner="${inner%[Mm]}"
            local btn col row
            IFS=';' read -r btn col row <<< "$inner"

            case "$etype/$btn" in
                M/0)            # left-button press
                    local hit
                    hit=$(row_to_item "$row")
                    if (( hit >= 0 )); then
                        sel=$hit
                        hover=-1
                        drain_input              # discard the release event
                        draw_menu "$sel" -1      # flash the selection
                        activate "$sel"
                        last_sel=-1
                        last_hover=-1
                    fi
                    ;;
                M/35)           # hover — visual only, inline hit-test (no subshell)
                    hover=-1
                    local _i _s
                    for (( _i=0; _i<${#LABELS[@]}; _i++ )); do
                        _s=${ITEM_START_ROWS[$_i]}
                        if (( row >= _s && row <= _s + 2 )); then
                            hover=$_i; break
                        fi
                    done
                    ;;
                M/64)           # scroll wheel up
                    (( sel = (sel - 1 + n) % n ))
                    hover=-1
                    ;;
                M/65)           # scroll wheel down
                    (( sel = (sel + 1) % n ))
                    hover=-1
                    ;;
            esac
        fi
    done
}

main
