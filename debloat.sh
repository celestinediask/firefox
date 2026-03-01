#!/usr/bin/env bash
# debloat-firefox.sh — Disable Firefox telemetry, Pocket, sponsored content, and more
# Supports: Debian/Ubuntu, Fedora/RHEL, Arch Linux (and derivatives)
# Mechanisms: user.js (per-profile) and policies.json (system-wide)

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
MANIFEST_DIR="$HOME/.local/share/debloat-firefox"
MANIFEST_FILE="$MANIFEST_DIR/manifest"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

# ---------------------------------------------------------------------------
# Color output (only when stdout is a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()    { printf "${GREEN}[INFO]${RESET}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
header()  { printf "\n${BOLD}${BLUE}==> %s${RESET}\n" "$*"; }
dry_run() { printf "${YELLOW}[DRY-RUN]${RESET} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Default option flags
# ---------------------------------------------------------------------------
DO_USER=true
DO_SYSTEM=true
DO_REMOVE_PKGS=false
DRY_RUN=false
DO_RESTORE=false

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}debloat-firefox.sh${RESET} v${SCRIPT_VERSION}

Disable Firefox telemetry, Pocket, sponsored content, crash reports, and more.

${BOLD}USAGE${RESET}
    $(basename "$0") [OPTIONS]

${BOLD}OPTIONS${RESET}
    -u, --user-only      Apply user.js to profiles only (no root required)
    -s, --system-only    Apply policies.json only (requires root/sudo)
    -r, --remove-pkgs    Remove extra locale/language packages
    -d, --dry-run        Preview changes without writing any files
        --restore        Restore original files and remove files added by this script
    -h, --help           Show this help message

${BOLD}EXAMPLES${RESET}
    # Preview everything (safe, no writes)
    $(basename "$0") --dry-run

    # Apply only user-level prefs (no sudo needed)
    $(basename "$0") --user-only

    # Apply everything including system policy
    $(basename "$0")

    # Undo all changes made by this script
    $(basename "$0") --restore
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    local user_only=false
    local system_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user-only)    user_only=true;    shift ;;
            -s|--system-only)  system_only=true;  shift ;;
            -r|--remove-pkgs)  DO_REMOVE_PKGS=true; shift ;;
            -d|--dry-run)      DRY_RUN=true;      shift ;;
            --restore)         DO_RESTORE=true;   shift ;;
            -h|--help)         usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if $user_only && $system_only; then
        error "--user-only and --system-only are mutually exclusive"
        exit 1
    fi
    if $user_only;   then DO_SYSTEM=false; fi
    if $system_only; then DO_USER=false;   fi
}

# ---------------------------------------------------------------------------
# Distro detection
# ---------------------------------------------------------------------------
detect_distro() {
    DISTRO_FAMILY="unknown"
    if [[ -f /etc/os-release ]]; then
        local id=""
        local id_like=""
        # shellcheck source=/dev/null
        id="$(. /etc/os-release && echo "${ID:-}")"
        id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"

        local combined="${id} ${id_like}"
        case "$combined" in
            *debian*|*ubuntu*)  DISTRO_FAMILY="debian" ;;
            *fedora*|*rhel*|*centos*|*alma*|*rocky*) DISTRO_FAMILY="fedora" ;;
            *arch*|*manjaro*)   DISTRO_FAMILY="arch"   ;;
        esac
    fi
    info "Detected distro family: ${BOLD}${DISTRO_FAMILY}${RESET}"
}

# ---------------------------------------------------------------------------
# Firefox install detection
# ---------------------------------------------------------------------------
detect_firefox_installs() {
    FIREFOX_INSTALLS=()

    local candidates=(
        "/usr/lib/firefox"
        "/usr/lib/firefox-esr"
        "/usr/lib64/firefox"
        "/snap/firefox/current/usr/lib/firefox"
        "$HOME/.local/share/flatpak/app/org.mozilla.firefox/current/active/files/lib/firefox"
        "/var/lib/flatpak/app/org.mozilla.firefox/current/active/files/lib/firefox"
    )

    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            FIREFOX_INSTALLS+=("$dir")
            info "Found Firefox install: $dir"
        fi
    done

    if [[ ${#FIREFOX_INSTALLS[@]} -eq 0 ]]; then
        warn "No Firefox installations found on standard paths"
    fi
}

# ---------------------------------------------------------------------------
# Profile detection
# ---------------------------------------------------------------------------
detect_profiles() {
    PROFILE_DIRS=()

    local ini_files=(
        "$HOME/.mozilla/firefox/profiles.ini"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini"
    )

    for ini in "${ini_files[@]}"; do
        if [[ ! -f "$ini" ]]; then
            continue
        fi
        local base_dir
        base_dir="$(dirname "$ini")"
        info "Parsing profile list: $ini"

        while IFS= read -r line; do
            if [[ "$line" =~ ^Path=(.+)$ ]]; then
                local path="${BASH_REMATCH[1]}"
                local full_path
                # Relative paths are relative to the profiles.ini directory
                if [[ "$path" = /* ]]; then
                    full_path="$path"
                else
                    full_path="$base_dir/$path"
                fi
                if [[ -d "$full_path" ]]; then
                    PROFILE_DIRS+=("$full_path")
                    info "Found profile: $full_path"
                fi
            fi
        done < "$ini"
    done

    if [[ ${#PROFILE_DIRS[@]} -eq 0 ]]; then
        warn "No Firefox profiles found (is Firefox installed and has been run at least once?)"
    fi
}

# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------
manifest_record_backup() {
    local original="$1"
    local backup="$2"
    mkdir -p "$MANIFEST_DIR"
    echo "BACKED_UP:${original}:${backup}" >> "$MANIFEST_FILE"
}

manifest_record_created() {
    local path="$1"
    mkdir -p "$MANIFEST_DIR"
    echo "CREATED:${path}" >> "$MANIFEST_FILE"
}

# Check if path is already recorded in manifest (so we don't double-backup)
manifest_has_entry() {
    local path="$1"
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        return 1
    fi
    grep -qF ":${path}:" "$MANIFEST_FILE" || grep -qF "CREATED:${path}" "$MANIFEST_FILE"
}

# ---------------------------------------------------------------------------
# File write helper
# Respects --dry-run, handles backup, handles sudo for system paths
# ---------------------------------------------------------------------------
write_file() {
    local dest="$1"
    local content="$2"
    local needs_sudo="${3:-false}"

    if $DRY_RUN; then
        dry_run "Would write: $dest"
        return 0
    fi

    # Backup existing file if not already backed up
    if [[ -f "$dest" ]] && ! manifest_has_entry "$dest"; then
        local backup="${dest}.debloat-backup.${TIMESTAMP}"
        if $needs_sudo; then
            sudo cp -- "$dest" "$backup"
        else
            cp -- "$dest" "$backup"
        fi
        manifest_record_backup "$dest" "$backup"
        info "Backed up: $dest → $backup"
    elif [[ ! -f "$dest" ]]; then
        manifest_record_created "$dest"
    fi

    # Ensure parent directory exists
    local dest_dir
    dest_dir="$(dirname "$dest")"
    if $needs_sudo; then
        sudo mkdir -p "$dest_dir"
        printf '%s' "$content" | sudo tee "$dest" > /dev/null
    else
        mkdir -p "$dest_dir"
        printf '%s' "$content" > "$dest"
    fi

    info "Written: $dest"
}

# ---------------------------------------------------------------------------
# user.js content
# ---------------------------------------------------------------------------
build_user_js() {
    cat <<'USERJS'
// debloat-firefox user.js
// Generated by debloat-firefox.sh — do not edit manually
// Remove this file to restore defaults (or use --restore flag)

// --- Telemetry ---
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.hybridContent.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);
user_pref("toolkit.telemetry.server", "data:,");

// --- Data Reporting ---
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.sessions.current.clean", true);

// --- Crash Reporter ---
user_pref("breakpad.reportURL", "");
user_pref("browser.crashReports.unsubmittedCheck.enabled", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("browser.tabs.crashReporting.requestEmail", false);

// --- Studies / Normandy ---
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("app.normandy.api_url", "");

// --- Pocket ---
user_pref("extensions.pocket.enabled", false);
user_pref("extensions.pocket.api", "");
user_pref("extensions.pocket.oAuthConsumerKey", "");
user_pref("extensions.pocket.showHome", false);

// --- Homepage / new tab (blank) ---
user_pref("browser.startup.page", 0);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.newtabpage.enabled", false);

// --- Sponsored / Activity Stream content ---
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.snippets", false);
user_pref("browser.newtabpage.activity-stream.feeds.discoverystreamfeed", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includePocket", false);
user_pref("browser.newtabpage.activity-stream.discoverystream.enabled", false);

// --- Firefox Home ads ---
user_pref("browser.topsites.contile.enabled", false);
user_pref("browser.topsites.useRemoteSetting", false);

// --- Annoyances ---
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.uitour.enabled", false);
user_pref("browser.uitour.url", "");
user_pref("devtools.onboarding.telemetry.logged", true);

// --- about:config warning ---
user_pref("browser.aboutConfig.showWarning", false);

// --- URL bar suggestions (all) ---
user_pref("browser.urlbar.quicksuggest.enabled", false);
user_pref("browser.urlbar.quicksuggest.remoteSettings.enabled", false);
user_pref("browser.urlbar.quicksuggest.dataCollection.enabled", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.history", false);
user_pref("browser.urlbar.suggest.bookmark", false);
user_pref("browser.urlbar.suggest.openpage", false);
user_pref("browser.urlbar.suggest.topsites", false);
user_pref("browser.urlbar.suggest.engines", false);
user_pref("browser.urlbar.suggest.remotetab", false);
user_pref("browser.urlbar.suggest.calculator", false);
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("browser.urlbar.autoFill", false);

// --- Web search from address bar ---
user_pref("keyword.enabled", false);

// --- Bookmarks toolbar ---
user_pref("browser.toolbars.bookmarks.visibility", "never");

// --- Clear all data on shutdown (history, cookies, cache, sessions) ---
// privacy.history.custom = true switches Firefox into "custom history" mode,
// which is required for the sanitizeOnShutdown prefs to be respected.
user_pref("privacy.history.custom", true);
user_pref("privacy.sanitize.sanitizeOnShutdown", true);
user_pref("privacy.sanitize.timeSpan", 0);
user_pref("privacy.clearOnShutdown.cache", true);
user_pref("privacy.clearOnShutdown.cookies", true);
user_pref("privacy.clearOnShutdown.downloads", true);
user_pref("privacy.clearOnShutdown.formdata", true);
user_pref("privacy.clearOnShutdown.history", true);
user_pref("privacy.clearOnShutdown.offlineApps", true);
user_pref("privacy.clearOnShutdown.sessions", true);
// Firefox 128+ names for the same settings
user_pref("privacy.clearOnShutdown_v2.cache", true);
user_pref("privacy.clearOnShutdown_v2.cookiesAndStorage", true);
user_pref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", true);
// Disable session restore — prevents "open previous tabs" notification.
user_pref("browser.sessionstore.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.resuming_after_os_restart", false);
user_pref("browser.sessionstore.max_tabs_undo", 0);
user_pref("browser.sessionstore.max_windows_undo", 0);
// THE key pref: Firefox increments this counter each time it could have
// restored a previous session but didn't, and shows the "open previous tabs"
// notification when it is > 0.  Resetting to 0 on every startup kills it.
user_pref("browser.startup.couldRestoreSession.count", 0);

// Disable Firefox View (shows "recently closed tabs" / tab pickup panel)
user_pref("browser.tabs.firefox-view", false);
user_pref("browser.tabs.firefox-view-next", false);

// --- Downloads: always ask where to save ---
user_pref("browser.download.useDownloadDir", false);

// --- Saved passwords ---
user_pref("signon.rememberSignons", false);
user_pref("signon.autofillForms", false);
user_pref("signon.generation.enabled", false);
user_pref("signon.management.page.breach-alerts.enabled", false);

// --- HTTPS-only mode (normal and private browsing) ---
user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_ever_enabled", true);
user_pref("dom.security.https_only_mode_pbm", true);

// --- DNS over HTTPS (disabled; use system resolver) ---
user_pref("network.trr.mode", 5);
user_pref("network.trr.uri", "");

// --- DNS prefetch / network prediction ---
user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);
USERJS
}

# ---------------------------------------------------------------------------
# defaults/pref/debloat.js content
# Loaded by Firefox from $INSTALL/defaults/pref/ BEFORE any profile is created.
# pref()     → sets a default; user can still override via about:config
# lockPref() → hard-locked; Firefox itself cannot change it at runtime
# ---------------------------------------------------------------------------
build_defaults_js() {
    cat <<'DEFAULTS'
// debloat-firefox system-wide default preferences
// Generated by debloat-firefox.sh
// Location: $FIREFOX_INSTALL/defaults/pref/debloat.js
//
// Firefox loads every .js file in defaults/pref/ before creating or opening
// any profile, so these settings are active on the very first launch after
// "rm ~/.mozilla".  pref() sets a default the user can change; lockPref()
// prevents Firefox from overriding the value at runtime.

// --- Telemetry ---
pref("toolkit.telemetry.enabled", false);
pref("toolkit.telemetry.unified", false);
pref("toolkit.telemetry.archive.enabled", false);
pref("toolkit.telemetry.bhrPing.enabled", false);
pref("toolkit.telemetry.firstShutdownPing.enabled", false);
pref("toolkit.telemetry.hybridContent.enabled", false);
pref("toolkit.telemetry.newProfilePing.enabled", false);
pref("toolkit.telemetry.reportingpolicy.firstRun", false);
pref("toolkit.telemetry.shutdownPingSender.enabled", false);
pref("toolkit.telemetry.updatePing.enabled", false);
pref("toolkit.telemetry.server", "data:,");

// --- Data Reporting ---
pref("datareporting.healthreport.uploadEnabled", false);
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("datareporting.sessions.current.clean", true);

// --- Crash Reporter ---
pref("breakpad.reportURL", "");
pref("browser.crashReports.unsubmittedCheck.enabled", false);
pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);
pref("browser.tabs.crashReporting.sendReport", false);
pref("browser.tabs.crashReporting.requestEmail", false);

// --- Studies / Normandy ---
pref("app.shield.optoutstudies.enabled", false);
pref("app.normandy.enabled", false);
pref("app.normandy.api_url", "");

// --- Pocket ---
pref("extensions.pocket.enabled", false);
pref("extensions.pocket.api", "");
pref("extensions.pocket.oAuthConsumerKey", "");
pref("extensions.pocket.showHome", false);

// --- Homepage / new tab (blank) ---
pref("browser.startup.page", 0);
pref("browser.startup.homepage", "about:blank");
pref("browser.newtabpage.enabled", false);

// --- Sponsored / Activity Stream content ---
pref("browser.newtabpage.activity-stream.showSponsored", false);
pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
pref("browser.newtabpage.activity-stream.telemetry", false);
pref("browser.newtabpage.activity-stream.feeds.snippets", false);
pref("browser.newtabpage.activity-stream.feeds.discoverystreamfeed", false);
pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
pref("browser.newtabpage.activity-stream.section.highlights.includePocket", false);
pref("browser.newtabpage.activity-stream.discoverystream.enabled", false);

// --- Firefox Home ads ---
pref("browser.topsites.contile.enabled", false);
pref("browser.topsites.useRemoteSetting", false);

// --- Annoyances ---
pref("browser.shell.checkDefaultBrowser", false);
pref("browser.startup.homepage_override.mstone", "ignore");
pref("browser.messaging-system.whatsNewPanel.enabled", false);
pref("browser.uitour.enabled", false);
pref("browser.uitour.url", "");
pref("devtools.onboarding.telemetry.logged", true);
pref("browser.aboutConfig.showWarning", false);

// --- URL bar suggestions (all locked so new-profile setup cannot re-enable) ---
lockPref("browser.urlbar.quicksuggest.enabled", false);
lockPref("browser.urlbar.quicksuggest.remoteSettings.enabled", false);
lockPref("browser.urlbar.quicksuggest.dataCollection.enabled", false);
lockPref("browser.urlbar.suggest.quicksuggest.sponsored", false);
lockPref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
lockPref("browser.urlbar.suggest.searches", false);
lockPref("browser.urlbar.suggest.history", false);
lockPref("browser.urlbar.suggest.bookmark", false);
lockPref("browser.urlbar.suggest.openpage", false);
lockPref("browser.urlbar.suggest.topsites", false);
lockPref("browser.urlbar.suggest.engines", false);
lockPref("browser.urlbar.suggest.remotetab", false);
lockPref("browser.urlbar.suggest.calculator", false);
lockPref("browser.search.suggest.enabled", false);
lockPref("browser.urlbar.speculativeConnect.enabled", false);
lockPref("browser.urlbar.autoFill", false);

// --- Web search from address bar ---
lockPref("keyword.enabled", false);

// --- Bookmarks toolbar ---
// lockPref: Firefox sets this to "always" during new-profile setup when
// it imports bookmarks or runs the first-run wizard.  Locking "never"
// prevents that override.
lockPref("browser.toolbars.bookmarks.visibility", "never");

// --- Clear all data on shutdown ---
pref("privacy.history.custom", true);
pref("privacy.sanitize.sanitizeOnShutdown", true);
pref("privacy.sanitize.timeSpan", 0);
pref("privacy.clearOnShutdown.cache", true);
pref("privacy.clearOnShutdown.cookies", true);
pref("privacy.clearOnShutdown.downloads", true);
pref("privacy.clearOnShutdown.formdata", true);
pref("privacy.clearOnShutdown.history", true);
pref("privacy.clearOnShutdown.offlineApps", true);
pref("privacy.clearOnShutdown.sessions", true);
pref("privacy.clearOnShutdown_v2.cache", true);
pref("privacy.clearOnShutdown_v2.cookiesAndStorage", true);
pref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", true);

// --- Session restore ---
pref("browser.sessionstore.enabled", false);
pref("browser.sessionstore.resume_from_crash", false);
pref("browser.sessionstore.resuming_after_os_restart", false);
pref("browser.sessionstore.max_tabs_undo", 0);
pref("browser.sessionstore.max_windows_undo", 0);
// lockPref: Firefox increments this counter and shows "open previous tabs"
// when it is > 0.  Lock to 0 so it can never trigger the notification.
lockPref("browser.startup.couldRestoreSession.count", 0);

// --- Firefox View ---
pref("browser.tabs.firefox-view", false);
pref("browser.tabs.firefox-view-next", false);

// --- Downloads: always ask where to save ---
pref("browser.download.useDownloadDir", false);

// --- Saved passwords ---
pref("signon.rememberSignons", false);
pref("signon.autofillForms", false);
pref("signon.generation.enabled", false);
pref("signon.management.page.breach-alerts.enabled", false);

// --- HTTPS-only mode ---
pref("dom.security.https_only_mode", true);
pref("dom.security.https_only_mode_ever_enabled", true);
pref("dom.security.https_only_mode_pbm", true);

// --- DNS over HTTPS (disabled) ---
pref("network.trr.mode", 5);
pref("network.trr.uri", "");

// --- DNS prefetch / network prediction ---
pref("network.prefetch-next", false);
pref("network.dns.disablePrefetch", true);
pref("network.predictor.enabled", false);
DEFAULTS
}

# ---------------------------------------------------------------------------
# Apply defaults/pref/debloat.js to each Firefox install
# ---------------------------------------------------------------------------
apply_defaults_js() {
    header "Applying defaults/pref/debloat.js (pre-profile, system-wide)"

    if [[ ${#FIREFOX_INSTALLS[@]} -eq 0 ]]; then
        warn "No Firefox installations found — skipping defaults/pref/debloat.js"
        return 0
    fi

    local content
    content="$(build_defaults_js)"

    for install in "${FIREFOX_INSTALLS[@]}"; do
        local dest="$install/defaults/pref/debloat.js"
        write_file "$dest" "$content" true
    done
}

# ---------------------------------------------------------------------------
# policies.json content
# ---------------------------------------------------------------------------
build_policies_json() {
    cat <<'POLICIES'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableCrashReporter": true,
    "DisableDefaultBrowserAgent": true,
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "Homepage": {
      "URL": "about:blank",
      "Locked": false,
      "StartPage": "homepage"
    },
    "SearchSuggestEnabled": false,
    "SearchEngines": {
      "Remove": ["Google", "Bing", "Amazon.com", "eBay", "Twitter", "Wikipedia (en)"]
    },
    "PasswordManagerEnabled": false,
    "OfferToSaveLogins": false,
    "OfferToSaveLoginsDefault": false,
    "HTTPSOnlyMode": "force_enabled",
    "DNSOverHTTPS": {
      "Enabled": false,
      "Locked": true
    },
    "FirefoxHome": {
      "TopSites": false,
      "SponsoredTopSites": false,
      "Pocket": false,
      "SponsoredPocket": false,
      "Snippets": false,
      "Locked": false
    },
    "UserMessaging": {
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "SkipOnboarding": true,
      "MoreFromMozilla": false,
      "Locked": false
    }
  }
}
POLICIES
}

# ---------------------------------------------------------------------------
# Apply user.js to all detected profiles
# ---------------------------------------------------------------------------
apply_user_js() {
    header "Applying user.js to Firefox profiles"

    if [[ ${#PROFILE_DIRS[@]} -eq 0 ]]; then
        warn "No profiles to update — skipping user.js"
        return 0
    fi

    local content
    content="$(build_user_js)"

    for profile in "${PROFILE_DIRS[@]}"; do
        local dest="$profile/user.js"
        write_file "$dest" "$content" false
    done
}

# ---------------------------------------------------------------------------
# Apply policies.json
# ---------------------------------------------------------------------------
apply_policies_json() {
    header "Applying policies.json (system-wide)"

    local content
    content="$(build_policies_json)"

    # Universal path (also works with snap)
    write_file "/etc/firefox/policies/policies.json" "$content" true

    # Per-install distribution/ path
    for install in "${FIREFOX_INSTALLS[@]}"; do
        local dest="$install/distribution/policies.json"
        write_file "$dest" "$content" true
    done

    if [[ ${#FIREFOX_INSTALLS[@]} -eq 0 ]]; then
        info "No install-specific distribution/ directories to write (universal /etc/firefox path used)"
    fi
}

# ---------------------------------------------------------------------------
# Package removal
# ---------------------------------------------------------------------------
remove_packages() {
    header "Removing extra locale packages"

    # Determine current locale prefix (e.g. "en_US" → "en")
    local lang_code="${LANG:-en_US}"
    lang_code="${lang_code%%_*}"  # strip country code → "en"
    lang_code="${lang_code%%.*}"  # strip encoding

    case "$DISTRO_FAMILY" in
        debian)
            local pkgs
            # List installed firefox locale packages excluding user's locale
            pkgs="$(dpkg-query --show --showformat='${Package}\n' 'firefox-locale-*' 'firefox-esr-l10n-*' 2>/dev/null \
                | grep -v -E "firefox-(locale|esr-l10n)-${lang_code}" || true)"
            if [[ -z "$pkgs" ]]; then
                info "No extra locale packages to remove"
                return 0
            fi
            info "Packages to remove: $pkgs"
            if $DRY_RUN; then
                dry_run "Would run: sudo apt-get remove $pkgs"
            else
                # shellcheck disable=SC2086
                sudo apt-get remove -y $pkgs
            fi
            ;;
        fedora)
            local pkgs
            pkgs="$(rpm -qa --qf '%{NAME}\n' 'firefox-langpack-*' 2>/dev/null \
                | grep -v "firefox-langpack-${lang_code}" || true)"
            if [[ -z "$pkgs" ]]; then
                info "No extra langpack packages to remove"
                return 0
            fi
            info "Packages to remove: $pkgs"
            if $DRY_RUN; then
                dry_run "Would run: sudo dnf remove $pkgs"
            else
                # shellcheck disable=SC2086
                sudo dnf remove -y $pkgs
            fi
            ;;
        arch)
            info "Arch: locale data is bundled — no separate locale packages to remove"
            ;;
        *)
            warn "Unknown distro family — skipping package removal"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
do_restore() {
    header "Restoring original files"

    if [[ ! -f "$MANIFEST_FILE" ]]; then
        warn "No manifest found at $MANIFEST_FILE — nothing to restore"
        return 0
    fi

    local errors=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue

        if [[ "$line" == BACKED_UP:* ]]; then
            # Format: BACKED_UP:<original>:<backup>
            local rest="${line#BACKED_UP:}"
            local original="${rest%%:*}"
            local backup="${rest#*:}"

            if [[ -f "$backup" ]]; then
                local needs_sudo=false
                if [[ "$original" == /etc/* ]] || [[ "$original" == /usr/* ]] || [[ "$original" == /snap/* ]]; then
                    needs_sudo=true
                fi

                if $DRY_RUN; then
                    dry_run "Would restore: $backup → $original"
                else
                    if $needs_sudo; then
                        sudo cp -- "$backup" "$original" && sudo rm -- "$backup"
                    else
                        cp -- "$backup" "$original" && rm -- "$backup"
                    fi
                    info "Restored: $original"
                fi
            else
                warn "Backup not found: $backup (skipping $original)"
                ((errors++)) || true
            fi

        elif [[ "$line" == CREATED:* ]]; then
            local path="${line#CREATED:}"
            local needs_sudo=false
            if [[ "$path" == /etc/* ]] || [[ "$path" == /usr/* ]] || [[ "$path" == /snap/* ]]; then
                needs_sudo=true
            fi

            if [[ -f "$path" ]]; then
                if $DRY_RUN; then
                    dry_run "Would remove: $path"
                else
                    if $needs_sudo; then
                        sudo rm -- "$path"
                    else
                        rm -- "$path"
                    fi
                    info "Removed: $path"

                    # Remove parent dir if now empty (e.g. distribution/ or policies/)
                    local parent
                    parent="$(dirname "$path")"
                    if $needs_sudo; then
                        sudo rmdir --ignore-fail-on-non-empty "$parent" 2>/dev/null || true
                    else
                        rmdir --ignore-fail-on-non-empty "$parent" 2>/dev/null || true
                    fi
                fi
            else
                warn "File not found: $path (already removed?)"
            fi
        else
            warn "Unrecognised manifest entry: $line"
        fi
    done < "$MANIFEST_FILE"

    if ! $DRY_RUN; then
        rm -f "$MANIFEST_FILE"
        rmdir --ignore-fail-on-non-empty "$MANIFEST_DIR" 2>/dev/null || true
        info "Manifest removed"
    fi

    if [[ $errors -gt 0 ]]; then
        warn "Restore completed with $errors warning(s)"
    else
        info "Restore complete"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    printf "${BOLD}debloat-firefox.sh${RESET} v${SCRIPT_VERSION}\n"
    if $DRY_RUN; then
        printf '%s\n' "${YELLOW}--- DRY-RUN MODE: no files will be written ---${RESET}"
    fi

    if $DO_RESTORE; then
        do_restore
        exit 0
    fi

    detect_distro
    detect_firefox_installs
    detect_profiles

    if $DO_USER; then
        apply_user_js
    fi

    if $DO_SYSTEM; then
        apply_defaults_js
        apply_policies_json
    fi

    if $DO_REMOVE_PKGS; then
        remove_packages
    fi

    header "Done"
    if ! $DRY_RUN; then
        printf "\nVerify with:\n"
        printf "  about:policies  — should list active enterprise policies\n"
        printf "  about:config    — check e.g. extensions.pocket.enabled = false\n"
        printf "\nTo undo all changes: %s --restore\n" "$(basename "$0")"
    fi
}

main "$@"
