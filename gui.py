#!/usr/bin/env python3
"""gui.py — GTK3 desktop UI for debloat.sh"""

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk

import json, shlex, subprocess, threading, shutil, glob, time, os, sys

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
DEBLOAT     = os.path.join(SCRIPT_DIR, 'debloat.sh')
LOG_FILE    = os.path.join(SCRIPT_DIR, 'gui.log')
PREFS_FILE  = os.path.join(SCRIPT_DIR, 'gui_prefs.json')

# ---------------------------------------------------------------------------
# CSS — minimal overrides that work with any system theme
# ---------------------------------------------------------------------------
CSS = b"""
.action-row {
    border-radius: 8px;
    padding: 4px;
    transition: background-color 100ms ease;
}
.action-row:hover:not(:disabled) {
    background-color: alpha(currentColor, 0.07);
}
.action-row:disabled {
    opacity: 0.45;
}
.action-row .title {
    font-weight: bold;
}
.action-row .subtitle {
    font-size: 0.85em;
    opacity: 0.65;
}
.output-view text {
    font-family: monospace;
    font-size: 0.9em;
}
.options-list .title {
    font-weight: bold;
}
.options-list .subtitle {
    font-size: 0.85em;
    opacity: 0.65;
}
.options-list row {
    border-bottom: 1px solid alpha(currentColor, 0.08);
}
.options-list row:last-child {
    border-bottom: none;
}
"""

# ---------------------------------------------------------------------------
# Debloat categories
#
# Each entry:
#   id              - unique string key
#   label           - short display name
#   desc            - one-line description shown in dialog
#   default         - checked by default (bool)
#   prefs           - list of (pref_key, python_value, lock_in_sys)
#                       python_value: bool / int / str
#                       lock_in_sys: True -> lockPref() in defaults/pref/debloat.js
#   policy_fragment - dict merged into policies.json "policies" object
# ---------------------------------------------------------------------------
DEBLOAT_CATEGORIES = [
    {
        'id': 'telemetry',
        'label': 'Telemetry',
        'desc': 'Disable usage data and statistics sent to Mozilla.',
        'default': True,
        'prefs': [
            ('toolkit.telemetry.enabled',                      False,    False),
            ('toolkit.telemetry.unified',                      False,    False),
            ('toolkit.telemetry.archive.enabled',              False,    False),
            ('toolkit.telemetry.bhrPing.enabled',              False,    False),
            ('toolkit.telemetry.firstShutdownPing.enabled',    False,    False),
            ('toolkit.telemetry.hybridContent.enabled',        False,    False),
            ('toolkit.telemetry.newProfilePing.enabled',       False,    False),
            ('toolkit.telemetry.reportingpolicy.firstRun',     False,    False),
            ('toolkit.telemetry.shutdownPingSender.enabled',   False,    False),
            ('toolkit.telemetry.updatePing.enabled',           False,    False),
            ('toolkit.telemetry.server',                       'data:,', False),
        ],
        'policy_fragment': {'DisableTelemetry': True},
    },
    {
        'id': 'data_reporting',
        'label': 'Data Reporting',
        'desc': 'Disable health reports and data submission to Mozilla.',
        'default': True,
        'prefs': [
            ('datareporting.healthreport.uploadEnabled',         False, False),
            ('datareporting.policy.dataSubmissionEnabled',       False, False),
            ('datareporting.sessions.current.clean',             True,  False),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'crash_reporter',
        'label': 'Crash Reporter',
        'desc': 'Disable crash report submission.',
        'default': True,
        'prefs': [
            ('breakpad.reportURL',                                    '',    False),
            ('browser.crashReports.unsubmittedCheck.enabled',         False, False),
            ('browser.crashReports.unsubmittedCheck.autoSubmit2',     False, False),
            ('browser.tabs.crashReporting.sendReport',                False, False),
            ('browser.tabs.crashReporting.requestEmail',              False, False),
        ],
        'policy_fragment': {'DisableCrashReporter': True},
    },
    {
        'id': 'studies',
        'label': 'Studies & Normandy',
        'desc': 'Disable A/B tests, experiments, and Normandy remote configuration.',
        'default': True,
        'prefs': [
            ('app.shield.optoutstudies.enabled', False, False),
            ('app.normandy.enabled',             False, False),
            ('app.normandy.api_url',             '',    False),
        ],
        'policy_fragment': {'DisableFirefoxStudies': True},
    },
    {
        'id': 'pocket',
        'label': 'Pocket',
        'desc': 'Remove the Pocket read-later integration from the browser.',
        'default': True,
        'prefs': [
            ('extensions.pocket.enabled',           False, False),
            ('extensions.pocket.api',               '',    False),
            ('extensions.pocket.oAuthConsumerKey',  '',    False),
            ('extensions.pocket.showHome',           False, False),
        ],
        'policy_fragment': {
            'DisablePocket': True,
            'FirefoxHome': {'Pocket': False, 'SponsoredPocket': False},
        },
    },
    {
        'id': 'homepage',
        'label': 'Firefox Home: Hide Search Bar',
        'desc': 'Remove the search bar from the Firefox Home / new tab page.',
        'default': True,
        'prefs': [
            ('browser.newtabpage.activity-stream.showSearch', False, False),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'sponsored',
        'label': 'Sponsored & Recommended Content',
        'desc': 'Remove ads, sponsored tiles, and Activity Stream recommendations from new tab.',
        'default': True,
        'prefs': [
            ('browser.newtabpage.activity-stream.showSponsored',                  False, False),
            ('browser.newtabpage.activity-stream.showSponsoredTopSites',          False, False),
            ('browser.newtabpage.activity-stream.feeds.telemetry',                False, False),
            ('browser.newtabpage.activity-stream.telemetry',                      False, False),
            ('browser.newtabpage.activity-stream.feeds.snippets',                 False, False),
            ('browser.newtabpage.activity-stream.feeds.discoverystreamfeed',      False, False),
            ('browser.newtabpage.activity-stream.feeds.section.topstories',       False, False),
            ('browser.newtabpage.activity-stream.section.highlights.includePocket', False, False),
            ('browser.newtabpage.activity-stream.discoverystream.enabled',        False, False),
            ('browser.topsites.contile.enabled',                                  False, False),
            ('browser.topsites.useRemoteSetting',                                 False, False),
        ],
        'policy_fragment': {
            'FirefoxHome': {
                'TopSites': False,
                'SponsoredTopSites': False,
                'Snippets': False,
            },
        },
    },
    {
        'id': 'annoyances',
        'label': 'Annoyances',
        'desc': "Disable onboarding, What's New panel, UI tour, and default browser prompt.",
        'default': True,
        'prefs': [
            ('browser.shell.checkDefaultBrowser',                False,    False),
            ('browser.startup.homepage_override.mstone',        'ignore', False),
            ('browser.messaging-system.whatsNewPanel.enabled',  False,    False),
            ('browser.uitour.enabled',                          False,    False),
            ('browser.uitour.url',                              '',       False),
            ('devtools.onboarding.telemetry.logged',            True,     False),
            ('browser.aboutConfig.showWarning',                 False,    False),
        ],
        'policy_fragment': {
            'DisableDefaultBrowserAgent': True,
            'DontCheckDefaultBrowser':    True,
            'NoDefaultBookmarks':         True,
            'OverrideFirstRunPage':       '',
            'OverridePostUpdatePage':     '',
            'UserMessaging': {
                'WhatsNew':                  False,
                'ExtensionRecommendations':  False,
                'FeatureRecommendations':    False,
                'SkipOnboarding':            True,
                'MoreFromMozilla':           False,
            },
        },
    },
    {
        'id': 'url_bar',
        'label': 'URL Bar Suggestions',
        'desc': 'Disable address bar search suggestions, quick suggest, and autocomplete.',
        'default': True,
        'prefs': [
            ('browser.urlbar.quicksuggest.enabled',                       False, True),
            ('browser.urlbar.quicksuggest.remoteSettings.enabled',        False, True),
            ('browser.urlbar.quicksuggest.dataCollection.enabled',        False, True),
            ('browser.urlbar.suggest.quicksuggest.sponsored',             False, True),
            ('browser.urlbar.suggest.quicksuggest.nonsponsored',          False, True),
            ('browser.urlbar.suggest.searches',                           False, True),
            ('browser.urlbar.suggest.history',                            False, True),
            ('browser.urlbar.suggest.bookmark',                           False, True),
            ('browser.urlbar.suggest.openpage',                           False, True),
            ('browser.urlbar.suggest.topsites',                           False, True),
            ('browser.urlbar.suggest.engines',                            False, True),
            ('browser.urlbar.suggest.remotetab',                          False, True),
            ('browser.urlbar.suggest.calculator',                         False, True),
            ('browser.search.suggest.enabled',                            False, True),
            ('browser.urlbar.speculativeConnect.enabled',                 False, True),
            ('browser.urlbar.autoFill',                                   False, True),
        ],
        'policy_fragment': {
            'SearchSuggestEnabled': False,
            'SearchEngines': {
                'Remove': ['Google', 'Bing', 'Amazon.com', 'eBay', 'Twitter', 'Wikipedia (en)'],
            },
        },
    },
    {
        'id': 'web_search',
        'label': 'Web Search from Address Bar',
        'desc': 'Disable using the address bar as a search box (keyword search).',
        'default': True,
        'prefs': [
            ('keyword.enabled', False, True),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'bookmarks_toolbar',
        'label': 'Hide Bookmarks Toolbar',
        'desc': 'Keep the bookmarks toolbar hidden.',
        'default': True,
        'prefs': [
            ('browser.toolbars.bookmarks.visibility', 'never', True),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'clear_on_shutdown',
        'label': 'Clear Data on Shutdown',
        'desc': 'Wipe history, cookies, cache, and form data when Firefox exits.',
        'default': True,
        'prefs': [
            ('privacy.history.custom',                              True,  False),
            ('privacy.sanitize.sanitizeOnShutdown',                True,  False),
            ('privacy.sanitize.timeSpan',                          0,     False),
            ('privacy.clearOnShutdown.cache',                      True,  False),
            ('privacy.clearOnShutdown.cookies',                    True,  False),
            ('privacy.clearOnShutdown.downloads',                  True,  False),
            ('privacy.clearOnShutdown.formdata',                   True,  False),
            ('privacy.clearOnShutdown.history',                    True,  False),
            ('privacy.clearOnShutdown.offlineApps',                True,  False),
            ('privacy.clearOnShutdown.sessions',                   True,  False),
            ('privacy.clearOnShutdown_v2.cache',                   True,  False),
            ('privacy.clearOnShutdown_v2.cookiesAndStorage',       True,  False),
            ('privacy.clearOnShutdown_v2.historyFormDataAndDownloads', True, False),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'session_restore',
        'label': 'Session Restore & Firefox View',
        'desc': "Don't restore previous tabs on startup; hide Firefox View.",
        'default': True,
        'prefs': [
            ('browser.sessionstore.enabled',                     False, False),
            ('browser.sessionstore.resume_from_crash',           False, False),
            ('browser.sessionstore.resuming_after_os_restart',   False, False),
            ('browser.sessionstore.max_tabs_undo',               0,     False),
            ('browser.sessionstore.max_windows_undo',            0,     False),
            ('browser.startup.couldRestoreSession.count',        0,     True),
            ('browser.tabs.firefox-view',                        False, False),
            ('browser.tabs.firefox-view-next',                   False, False),
        ],
        'policy_fragment': {},
    },
    {
        'id': 'downloads',
        'label': 'Downloads: Always Ask Location',
        'desc': 'Prompt for a save location instead of using a default download folder.',
        'default': True,
        'prefs': [
            ('browser.download.useDownloadDir', False, False),
        ],
        'policy_fragment': {'PromptForDownloadLocation': True},
    },
    {
        'id': 'passwords',
        'label': 'Saved Passwords',
        'desc': 'Disable the built-in password manager and login autofill.',
        'default': True,
        'prefs': [
            ('signon.rememberSignons',                          False, False),
            ('signon.autofillForms',                            False, False),
            ('signon.generation.enabled',                       False, False),
            ('signon.management.page.breach-alerts.enabled',   False, False),
        ],
        'policy_fragment': {
            'PasswordManagerEnabled':     False,
            'OfferToSaveLogins':          False,
            'OfferToSaveLoginsDefault':   False,
        },
    },
    {
        'id': 'https_only',
        'label': 'HTTPS-Only Mode',
        'desc': 'Force HTTPS on all connections, including private browsing.',
        'default': True,
        'prefs': [
            ('dom.security.https_only_mode',              True, False),
            ('dom.security.https_only_mode_ever_enabled', True, False),
            ('dom.security.https_only_mode_pbm',          True, False),
        ],
        'policy_fragment': {'HTTPSOnlyMode': 'force_enabled'},
    },
    {
        'id': 'dns_https',
        'label': 'DNS over HTTPS (disabled)',
        'desc': "Use the system DNS resolver instead of Firefox's built-in DoH.",
        'default': True,
        'prefs': [
            ('network.trr.mode', 5,  False),
            ('network.trr.uri',  '', False),
        ],
        'policy_fragment': {'DNSOverHTTPS': {'Enabled': False, 'Locked': True}},
    },
    {
        'id': 'dns_prefetch',
        'label': 'DNS Prefetch & Network Prediction',
        'desc': 'Disable speculative DNS lookups and connection prefetching.',
        'default': True,
        'prefs': [
            ('network.prefetch-next',           False, False),
            ('network.dns.disablePrefetch',     True,  False),
            ('network.predictor.enabled',       False, False),
        ],
        'policy_fragment': {},
    },
]

# ---------------------------------------------------------------------------
# Content generators
# ---------------------------------------------------------------------------

def _js_value(v):
    """Format a Python value as a Firefox JS pref literal."""
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return str(v)
    return f'"{v}"'


def _build_user_js(selected_ids):
    lines = [
        '// debloat-firefox user.js',
        '// Generated by gui.py -- remove this file to restore defaults',
        '',
    ]
    for cat in DEBLOAT_CATEGORIES:
        if cat['id'] not in selected_ids:
            continue
        prefs = cat.get('prefs', [])
        if not prefs:
            continue
        lines.append(f'// --- {cat["label"]} ---')
        for key, val, _lock in prefs:
            lines.append(f'user_pref("{key}", {_js_value(val)});')
        lines.append('')
    return '\n'.join(lines)


def _build_defaults_js(selected_ids):
    lines = [
        '// debloat-firefox system-wide defaults',
        '// Generated by gui.py',
        '// Location: $FIREFOX_INSTALL/defaults/pref/debloat.js',
        '',
    ]
    for cat in DEBLOAT_CATEGORIES:
        if cat['id'] not in selected_ids:
            continue
        prefs = cat.get('prefs', [])
        if not prefs:
            continue
        lines.append(f'// --- {cat["label"]} ---')
        for key, val, lock in prefs:
            fn = 'lockPref' if lock else 'pref'
            lines.append(f'{fn}("{key}", {_js_value(val)});')
        lines.append('')
    return '\n'.join(lines)


def _deep_merge(base, overlay):
    for k, v in overlay.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v


def _build_policies_json(selected_ids):
    policies = {}
    for cat in DEBLOAT_CATEGORIES:
        if cat['id'] not in selected_ids:
            continue
        frag = cat.get('policy_fragment', {})
        if frag:
            _deep_merge(policies, frag)
    return json.dumps({'policies': policies}, indent=2)


def _load_debloat_prefs():
    """Return saved {category_id: bool} dict, or {} if not found."""
    try:
        with open(PREFS_FILE, encoding='utf-8') as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {}


def _save_debloat_prefs(states):
    """Persist {category_id: bool} dict to disk."""
    try:
        with open(PREFS_FILE, 'w', encoding='utf-8') as f:
            json.dump(states, f, indent=2)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Action definitions
# ---------------------------------------------------------------------------
ACTIONS = [
    {
        'id':      'debloat',
        'label':   'Debloat Firefox',
        'desc':    'Disable telemetry, Pocket, sponsored content, address-bar '
                   'suggestions, HTTPS-only mode and more.',
        'icon':    'security-high-symbolic',
        'confirm': None,
    },
    {
        'id':      'clear',
        'label':   'Clear User Data',
        'desc':    'Delete ~/.mozilla and ~/.cache/mozilla. '
                   'All profiles, history and cookies are wiped.',
        'icon':    'edit-clear-all-symbolic',
        'confirm': 'This will permanently delete ~/.mozilla and ~/.cache/mozilla.\n'
                   'All profiles, history and cookies will be wiped.',
    },
    {
        'id':      'restore',
        'label':   'Restore Factory Settings',
        'desc':    'Remove all debloat files and wipe user data. '
                   'Firefox starts completely fresh on next launch.',
        'icon':    'document-revert-symbolic',
        'confirm': 'This will remove all debloat files and wipe ~/.mozilla.\n'
                   'Firefox will start completely fresh on next launch.',
    },
    {
        'id':      'restart',
        'label':   'Restart Firefox',
        'desc':    'Close all Firefox windows and relaunch the browser. '
                   'Useful to apply profile changes immediately.',
        'icon':    'view-refresh-symbolic',
        'confirm': 'This will close all Firefox windows and relaunch.',
    },
    {
        'id':      'start',
        'label':   'Start Firefox',
        'desc':    'Launch the Firefox browser.',
        'icon':    'media-playback-start-symbolic',
        'confirm': None,
    },
    {
        'id':      'stop',
        'label':   'Quit Firefox',
        'desc':    'Close all running Firefox windows.',
        'icon':    'media-playback-stop-symbolic',
        'confirm': 'This will close all Firefox windows.',
    },
]

# ---------------------------------------------------------------------------
# Debloat options dialog
# ---------------------------------------------------------------------------

class DebloatOptionsDialog(Gtk.Dialog):

    def __init__(self, parent):
        super().__init__(title='Debloat Options', transient_for=parent, modal=True)
        self.set_default_size(560, 600)
        self.add_button('_Cancel', Gtk.ResponseType.CANCEL)
        apply_btn = self.add_button('_Apply', Gtk.ResponseType.OK)
        apply_btn.get_style_context().add_class('suggested-action')

        content = self.get_content_area()
        content.set_spacing(0)

        intro = Gtk.Label(
            label='Select which settings to apply. All items are enabled by default.',
            xalign=0,
            wrap=True,
        )
        intro.set_margin_start(16)
        intro.set_margin_end(16)
        intro.set_margin_top(14)
        intro.set_margin_bottom(10)
        intro.get_style_context().add_class('dim-label')
        content.add(intro)

        tbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        tbar.set_margin_start(16)
        tbar.set_margin_bottom(10)
        all_btn  = Gtk.Button(label='Select All')
        none_btn = Gtk.Button(label='Deselect All')
        all_btn.connect('clicked',  lambda _: self._set_all(True))
        none_btn.connect('clicked', lambda _: self._set_all(False))
        tbar.pack_start(all_btn,  False, False, 0)
        tbar.pack_start(none_btn, False, False, 0)
        content.add(tbar)

        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_margin_start(12)
        scroll.set_margin_end(12)
        scroll.set_margin_bottom(12)

        list_box = Gtk.ListBox()
        list_box.set_selection_mode(Gtk.SelectionMode.NONE)
        list_box.get_style_context().add_class('frame')
        list_box.get_style_context().add_class('options-list')
        scroll.add(list_box)
        content.add(scroll)

        self._checks = {}
        for cat in DEBLOAT_CATEGORIES:
            list_box.add(self._make_row(cat))

        # Restore previously saved checkbox states
        saved = _load_debloat_prefs()
        for cid, check in self._checks.items():
            if cid in saved:
                check.set_active(bool(saved[cid]))

        self.show_all()

    def _make_row(self, cat):
        row = Gtk.ListBoxRow()
        row.set_activatable(False)
        row.set_selectable(False)

        outer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)

        check = Gtk.CheckButton()
        check.set_active(cat['default'])
        check.set_valign(Gtk.Align.CENTER)
        check.set_margin_start(12)
        check.set_margin_end(6)
        check.set_margin_top(10)
        check.set_margin_bottom(10)
        self._checks[cat['id']] = check
        outer.pack_start(check, False, False, 0)

        text_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        text_col.set_margin_end(12)
        text_col.set_margin_top(10)
        text_col.set_margin_bottom(10)

        title_lbl = Gtk.Label(label=cat['label'], xalign=0)
        title_lbl.get_style_context().add_class('title')
        text_col.pack_start(title_lbl, False, False, 0)

        desc_lbl = Gtk.Label(label=cat['desc'], xalign=0, wrap=True)
        desc_lbl.set_max_width_chars(58)
        desc_lbl.get_style_context().add_class('subtitle')
        text_col.pack_start(desc_lbl, False, False, 0)

        text_btn = Gtk.Button()
        text_btn.set_relief(Gtk.ReliefStyle.NONE)
        text_btn.add(text_col)
        text_btn.connect('clicked', lambda _, c: c.set_active(not c.get_active()), check)
        outer.pack_start(text_btn, True, True, 0)

        row.add(outer)
        return row

    def _set_all(self, active):
        for check in self._checks.values():
            check.set_active(active)

    def get_selected_ids(self):
        return {cid for cid, check in self._checks.items() if check.get_active()}

    def get_states(self):
        """Return {category_id: bool} for all checkboxes."""
        return {cid: check.get_active() for cid, check in self._checks.items()}


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='io.github.firefox_debloat')

    def do_activate(self):
        win = MainWindow(application=self)
        win.present()


class MainWindow(Gtk.ApplicationWindow):

    def __init__(self, **kwargs):
        super().__init__(
            title='Firefox Debloat',
            default_width=580,
            default_height=600,
            **kwargs,
        )
        self._busy = False
        self._log_file = None
        try:
            self._log_file = open(LOG_FILE, 'a', buffering=1, encoding='utf-8')
        except OSError:
            pass
        self.connect('destroy', self._on_destroy)
        self._apply_css()
        self._build()

    # -- CSS ------------------------------------------------------------------

    def _apply_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    # -- Layout ---------------------------------------------------------------

    def _build(self):
        hb = Gtk.HeaderBar(
            title='Firefox Debloat',
            subtitle='Privacy & performance hardening',
            show_close_button=True,
        )
        self.set_titlebar(hb)
        self._spinner = Gtk.Spinner()
        hb.pack_end(self._spinner)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(root)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        btn_box.set_margin_top(16)
        btn_box.set_margin_bottom(12)
        btn_box.set_margin_start(16)
        btn_box.set_margin_end(16)
        root.pack_start(btn_box, False, False, 0)

        self._btns = {}
        for action in ACTIONS:
            btn = self._make_action_btn(action)
            btn_box.pack_start(btn, False, False, 0)
            self._btns[action['id']] = btn

        root.pack_start(Gtk.Separator(), False, False, 0)

        out_lbl = Gtk.Label(label='Output', xalign=0)
        out_lbl.set_margin_top(10)
        out_lbl.set_margin_start(16)
        out_lbl.get_style_context().add_class('dim-label')
        root.pack_start(out_lbl, False, False, 0)

        self._buf = Gtk.TextBuffer()
        tv = Gtk.TextView(
            buffer=self._buf,
            editable=False,
            cursor_visible=False,
            monospace=True,
            wrap_mode=Gtk.WrapMode.WORD_CHAR,
        )
        tv.get_style_context().add_class('output-view')
        tv.set_margin_top(4)
        tv.set_margin_bottom(4)
        tv.set_margin_start(4)
        tv.set_margin_end(4)
        self._tv = tv

        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.set_margin_top(4)
        scroll.set_margin_bottom(12)
        scroll.set_margin_start(16)
        scroll.set_margin_end(16)
        scroll.add(tv)
        root.pack_start(scroll, True, True, 0)

        self.show_all()
        self._spinner.hide()

    def _make_action_btn(self, action):
        btn = Gtk.Button()
        btn.get_style_context().add_class('action-row')
        btn.set_relief(Gtk.ReliefStyle.NONE)
        btn.connect('clicked', self._on_action, action)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        row.set_margin_top(8)
        row.set_margin_bottom(8)
        row.set_margin_start(8)
        row.set_margin_end(8)

        icon = Gtk.Image.new_from_icon_name(action['icon'], Gtk.IconSize.LARGE_TOOLBAR)
        row.pack_start(icon, False, False, 0)

        text_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)

        title = Gtk.Label(label=action['label'], xalign=0)
        title.get_style_context().add_class('title')
        text_col.pack_start(title, False, False, 0)

        desc = Gtk.Label(label=action['desc'], xalign=0, wrap=True)
        desc.set_max_width_chars(60)
        desc.get_style_context().add_class('subtitle')
        text_col.pack_start(desc, False, False, 0)

        row.pack_start(text_col, True, True, 0)

        arrow = Gtk.Image.new_from_icon_name('go-next-symbolic', Gtk.IconSize.BUTTON)
        row.pack_end(arrow, False, False, 0)

        btn.add(row)
        return btn

    # -- Action dispatch ------------------------------------------------------

    def _on_action(self, _btn, action):
        if self._busy:
            return

        if action['id'] == 'debloat':
            dlg = DebloatOptionsDialog(self)
            resp = dlg.run()
            selected = dlg.get_selected_ids()
            if resp == Gtk.ResponseType.OK:
                _save_debloat_prefs(dlg.get_states())
            dlg.destroy()
            if resp != Gtk.ResponseType.OK:
                return
            self._set_busy(True)
            self._buf.set_text('')
            self._write_log_header(action['label'])
            threading.Thread(
                target=self._run_debloat_with_options,
                args=(selected,),
                daemon=True,
            ).start()
            return

        if action['confirm'] and not self._confirm(action['confirm']):
            return
        self._set_busy(True)
        self._buf.set_text('')
        self._write_log_header(action['label'])
        threading.Thread(target=self._run, args=(action['id'],), daemon=True).start()

    def _write_log_header(self, label):
        if self._log_file:
            ts = time.strftime('%Y-%m-%d %H:%M:%S')
            self._log_file.write(f'\n{"=" * 60}\n[{ts}]  {label}\n{"=" * 60}\n')

    def _run(self, action_id):
        try:
            getattr(self, f'_do_{action_id}')()
        except Exception as exc:
            self._log(f'\nError: {exc}\n')
        GLib.idle_add(self._set_busy, False)

    def _run_debloat_with_options(self, selected_ids):
        try:
            self._do_debloat_with_options(selected_ids)
        except Exception as exc:
            self._log(f'\nError: {exc}\n')
        GLib.idle_add(self._set_busy, False)

    # -- Debloat with options -------------------------------------------------

    def _do_debloat_with_options(self, selected_ids):
        if not selected_ids:
            self._log('Nothing selected -- no changes made.\n')
            return

        self._log('==> Step 1/2 -- user.js to Firefox profiles\n\n')
        user_js = _build_user_js(selected_ids)
        profiles = self._find_profiles()
        if profiles:
            for profile in profiles:
                dest = os.path.join(profile, 'user.js')
                try:
                    with open(dest, 'w', encoding='utf-8') as f:
                        f.write(user_js)
                    self._log(f'  Written: {dest}\n')
                except OSError as e:
                    self._log(f'  Error: {dest}: {e}\n')
        else:
            self._log('  No Firefox profiles found\n')

        self._log('\n==> Step 2/2 -- system-wide settings (may prompt for sudo)\n\n')
        defaults_js       = _build_defaults_js(selected_ids)
        policies_json_str = _build_policies_json(selected_ids)
        installs = self._find_ff_installs()

        if installs:
            for install in installs:
                dest = os.path.join(install, 'defaults', 'pref', 'debloat.js')
                self._log(f'  Writing {dest}\n')
                if self._sudo_write(dest, defaults_js):
                    self._log('    OK\n')
        else:
            self._log('  No Firefox installations found; skipping defaults/pref/debloat.js\n')

        policy_dests = ['/etc/firefox/policies/policies.json']
        for install in installs:
            policy_dests.append(os.path.join(install, 'distribution', 'policies.json'))

        for dest in policy_dests:
            self._log(f'  Writing {dest}\n')
            if self._sudo_write(dest, policies_json_str):
                self._log('    OK\n')

        self._log('\n   Debloat complete. Restart Firefox for settings to take effect.\n')

    def _find_profiles(self):
        profiles = []
        ini_paths = [
            os.path.expanduser('~/.mozilla/firefox/profiles.ini'),
            os.path.expanduser('~/.var/app/org.mozilla.firefox/.mozilla/firefox/profiles.ini'),
        ]
        for ini in ini_paths:
            if not os.path.isfile(ini):
                continue
            base = os.path.dirname(ini)
            try:
                with open(ini, encoding='utf-8', errors='replace') as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith('Path='):
                            path = line[5:]
                            full = path if os.path.isabs(path) else os.path.join(base, path)
                            if os.path.isdir(full) and full not in profiles:
                                profiles.append(full)
            except OSError:
                pass
        return profiles

    def _find_ff_installs(self):
        candidates = [
            '/usr/lib/firefox',
            '/usr/lib/firefox-esr',
            '/usr/lib64/firefox',
            '/snap/firefox/current/usr/lib/firefox',
            os.path.expanduser(
                '~/.local/share/flatpak/app/org.mozilla.firefox'
                '/current/active/files/lib/firefox'
            ),
            '/var/lib/flatpak/app/org.mozilla.firefox/current/active/files/lib/firefox',
        ]
        return [d for d in candidates if os.path.isdir(d)]

    def _sudo_write(self, dest, content):
        parent = os.path.dirname(dest)
        script = (
            f'mkdir -p {shlex.quote(parent)} && '
            f'tee {shlex.quote(dest)}'
        )
        proc = subprocess.Popen(
            ['sudo', 'bash', '-c', script],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        _, err = proc.communicate(content.encode('utf-8'))
        if proc.returncode != 0:
            self._log(f'    sudo failed: {err.decode(errors="replace").strip()}\n')
            return False
        return True

    # -- Other actions --------------------------------------------------------

    def _do_clear(self):
        self._log('==> Clearing Firefox user data\n\n')
        for p in ('~/.mozilla', '~/.cache/mozilla'):
            path = os.path.expanduser(p)
            if os.path.exists(path):
                shutil.rmtree(path)
                self._log(f'  Removed {path}\n')
            else:
                self._log(f'  {path} -- not found (already clean)\n')
        self._log('\n   User data cleared.\n')

    def _do_restore(self):
        self._log('==> Removing system debloat files\n\n')
        sys_files = [
            '/usr/lib/firefox-esr/defaults/pref/debloat.js',
            '/usr/lib/firefox/defaults/pref/debloat.js',
            '/etc/firefox/policies/policies.json',
            '/usr/lib/firefox-esr/distribution/policies.json',
            '/usr/lib/firefox/distribution/policies.json',
            '/snap/firefox/current/usr/lib/firefox/distribution/policies.json',
        ]
        found = False
        for f in sys_files:
            if os.path.exists(f):
                self._shell(['sudo', 'rm', '-f', '--', f])
                self._log(f'  Removed {f}\n')
                found = True
        if not found:
            self._log('  No system debloat files found\n')

        self._log('\n==> Removing user.js from profiles\n\n')
        js_files = glob.glob(os.path.expanduser('~/.mozilla/firefox/*/user.js'))
        for js in js_files:
            os.remove(js)
            self._log(f'  Removed {js}\n')
        if not js_files:
            self._log('  No profile user.js files found\n')

        self._log('\n==> Clearing user data\n\n')
        for p in ('~/.mozilla', '~/.cache/mozilla'):
            path = os.path.expanduser(p)
            if os.path.exists(path):
                shutil.rmtree(path)
                self._log(f'  Removed {path}\n')
            else:
                self._log(f'  {path} -- not found\n')

        manifest = os.path.expanduser('~/.local/share/debloat-firefox/manifest')
        if os.path.exists(manifest):
            os.remove(manifest)
            try:
                os.rmdir(os.path.dirname(manifest))
            except OSError:
                pass
            self._log('  Removed manifest\n')

        self._log('\n   Factory reset complete. Firefox will start fresh on next launch.\n')

    def _do_restart(self):
        self._log('==> Stopping Firefox\n\n')
        killed = False
        for name in ('firefox-esr', 'firefox'):
            if subprocess.run(['pkill', '-x', name], capture_output=True).returncode == 0:
                self._log(f'  Sent stop signal to {name}\n')
                killed = True
        if not killed:
            self._log('  No running Firefox instance found\n')

        waited = 0.0
        while waited < 5.0:
            r1 = subprocess.run(['pgrep', '-x', 'firefox-esr'], capture_output=True)
            r2 = subprocess.run(['pgrep', '-x', 'firefox'],     capture_output=True)
            if r1.returncode != 0 and r2.returncode != 0:
                break
            time.sleep(0.5)
            waited += 0.5
        else:
            self._log('  Force-killing Firefox...\n')
            for name in ('firefox-esr', 'firefox'):
                subprocess.run(['pkill', '-9', '-x', name], capture_output=True)
            time.sleep(0.5)

        self._log('\n==> Launching Firefox\n\n')
        ff = shutil.which('firefox-esr') or shutil.which('firefox')
        if ff:
            subprocess.Popen(
                [ff],
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._log(f'  Launched {ff}\n')
            self._log('\n   Firefox restarted.\n')
        else:
            self._log('  Could not find firefox or firefox-esr in PATH\n')

    def _do_start(self):
        ff = shutil.which('firefox-esr') or shutil.which('firefox')
        if ff:
            subprocess.Popen(
                [ff],
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._log(f'  Launched {ff}\n')
            self._log('\n   Firefox started.\n')
        else:
            self._log('  Could not find firefox or firefox-esr in PATH\n')

    def _do_stop(self):
        self._log('==> Stopping Firefox\n\n')
        killed = False
        for name in ('firefox-esr', 'firefox'):
            if subprocess.run(['pkill', '-x', name], capture_output=True).returncode == 0:
                self._log(f'  Sent stop signal to {name}\n')
                killed = True
        if not killed:
            self._log('  No running Firefox instance found\n')
        else:
            self._log('\n   Firefox stopped.\n')

    # -- Helpers --------------------------------------------------------------

    def _shell(self, cmd):
        """Run cmd, streaming stdout+stderr line-by-line to the output view."""
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for line in proc.stdout:
            self._log(line)
        proc.wait()

    def _log(self, text):
        GLib.idle_add(self._append, text)

    def _append(self, text):
        it = self._buf.get_end_iter()
        self._buf.insert(it, text)
        self._tv.scroll_to_iter(self._buf.get_end_iter(), 0, False, 0, 1.0)
        if self._log_file:
            self._log_file.write(text)

    def _on_destroy(self, _):
        if self._log_file:
            self._log_file.close()

    def _set_busy(self, busy):
        self._busy = busy
        for btn in self._btns.values():
            btn.set_sensitive(not busy)
        if busy:
            self._spinner.show()
            self._spinner.start()
        else:
            self._spinner.stop()
            self._spinner.hide()

    def _confirm(self, msg):
        dlg = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.YES_NO,
            text=msg,
        )
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.YES


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    if not os.path.exists(DEBLOAT):
        print(f'Error: debloat.sh not found at {DEBLOAT}', file=sys.stderr)
        sys.exit(1)
    sys.exit(App().run(sys.argv))
