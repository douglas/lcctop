"""
Main GTK4 session picker application.

Window lifecycle: destroy + recreate each invocation.
GtkApplication single-instance (D-Bus) handles toggle:
  - First invocation: acquire D-Bus name → do_activate → show window
  - Second invocation (window open): sends activate to first instance →
    do_activate sees window exists → close + quit
  - Second invocation (window closed): fresh process → do_activate → show window
"""

# gtk4-layer-shell must be loaded before any GI imports
from ctypes import CDLL
CDLL("libgtk4-layer-shell.so")

import gi
gi.require_version("Gtk",           "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gtk, GLib, Gdk
from gi.repository import Gtk4LayerShell as LayerShell

import os
import sys

from sessions import load_sessions
from focus    import focus_session
from colors   import load_colors, generate_css
from widgets  import build_picker_content, rebuild_session_list


_CSS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "style.css")


# ---------------------------------------------------------------------------
# Layer-shell setup
# ---------------------------------------------------------------------------

def setup_layer_shell(window: Gtk.Window) -> None:
    """Configure a GtkWindow as a full-screen layer-shell overlay."""
    LayerShell.init_for_window(window)
    LayerShell.set_layer(window, LayerShell.Layer.TOP)
    LayerShell.set_anchor(window, LayerShell.Edge.TOP,    True)
    LayerShell.set_anchor(window, LayerShell.Edge.BOTTOM, True)
    LayerShell.set_anchor(window, LayerShell.Edge.LEFT,   True)
    LayerShell.set_anchor(window, LayerShell.Edge.RIGHT,  True)
    LayerShell.set_exclusive_zone(window, -1)
    LayerShell.set_keyboard_mode(window, LayerShell.KeyboardMode.EXCLUSIVE)
    LayerShell.set_namespace(window, "lcctop-picker")


# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

class PickerApp(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id="com.lcctop.picker")
        self._window:        Gtk.Window | None = None
        self._sessions:      list[dict]        = []
        self._selected:      int               = 0
        self._card_boxes:    list[Gtk.Box]     = []
        self._list_box:      Gtk.Box | None    = None
        self._refresh_timer: int | None        = None

    # ------------------------------------------------------------------
    # Activate
    # ------------------------------------------------------------------

    def do_activate(self) -> None:
        # Toggle: if window is already open, close on second invocation.
        if self._window is not None:
            self._close()
            return

        self._sessions = load_sessions()
        self._selected = self._initial_selection()
        self._open()

    # ------------------------------------------------------------------
    # Open
    # ------------------------------------------------------------------

    def _initial_selection(self) -> int:
        for i, s in enumerate(self._sessions):
            if s.get("status") in ("waiting_permission", "waiting_input", "needs_attention"):
                return i
        return 0

    def _load_css(self) -> None:
        display = Gdk.Display.get_default()

        # 1. Static fallback from style.css (structural + Catppuccin Mocha defaults)
        if os.path.exists(_CSS_PATH):
            static = Gtk.CssProvider()
            static.load_from_path(_CSS_PATH)
            Gtk.StyleContext.add_provider_for_display(
                display, static,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )

        # 2. Theme colors (higher priority, overrides colors in static CSS)
        colors  = load_colors()
        dynamic = Gtk.CssProvider()
        dynamic.load_from_string(generate_css(colors))
        Gtk.StyleContext.add_provider_for_display(
            display, dynamic,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
        )

    def _open(self) -> None:
        self._load_css()

        win = Gtk.Window(application=self)
        win.add_css_class("lcctop-picker-window")
        self._window = win

        setup_layer_shell(win)

        # Root widget: semi-transparent scrim (full screen)
        scrim = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        scrim.add_css_class("picker-scrim")
        scrim.set_hexpand(True)
        scrim.set_vexpand(True)

        # Scrim click-to-close (only fires when not claimed by container)
        scrim_click = Gtk.GestureClick()
        scrim_click.connect("pressed", lambda *_: self._close())
        scrim.add_controller(scrim_click)

        # Center the picker container
        center = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        center.set_halign(Gtk.Align.CENTER)
        center.set_valign(Gtk.Align.CENTER)
        center.set_hexpand(True)
        center.set_vexpand(True)

        # Build picker content
        container, self._card_boxes = build_picker_content(
            self._sessions, self._selected,
        )
        # Store reference to the session list box for refresh
        self._list_box = self._find_list_box(container)

        # Container click — claim the event so scrim doesn't fire
        container_click = Gtk.GestureClick()
        container_click.connect(
            "pressed",
            lambda g, *_: g.set_state(Gtk.EventSequenceState.CLAIMED),
        )
        container.add_controller(container_click)

        center.append(container)
        scrim.append(center)
        win.set_child(scrim)

        # Key handler (CAPTURE phase so window intercepts before any child)
        key_ctrl = Gtk.EventControllerKey()
        key_ctrl.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        key_ctrl.connect("key-pressed", self._on_key_pressed)
        win.add_controller(key_ctrl)

        win.present()

        # Periodic session refresh
        self._refresh_timer = GLib.timeout_add(2000, self._refresh)

    def _find_list_box(self, container: Gtk.Box) -> Gtk.Box | None:
        """
        Walk the container's child tree to find the session list GtkBox.
        GtkScrolledWindow automatically wraps its child in a GtkViewport,
        so we need scrolled → viewport → list_box (two .get_child() calls).
        """
        child = container.get_first_child()
        while child:
            if isinstance(child, Gtk.ScrolledWindow):
                viewport = child.get_child()   # GtkViewport (auto-inserted by GTK)
                return viewport.get_child() if viewport else None
            child = child.get_next_sibling()
        return None

    # ------------------------------------------------------------------
    # Key handling
    # ------------------------------------------------------------------

    def _on_key_pressed(
        self,
        _ctrl:   Gtk.EventControllerKey,
        keyval:  int,
        _code:   int,
        _state:  Gdk.ModifierType,
    ) -> bool:
        GDK_j,      GDK_k      = 106,   107
        GDK_q,      GDK_Return = 113,   65293
        GDK_KPEnter             = 65421
        GDK_Escape, GDK_Down   = 65307, 65364
        GDK_Up                 = 65362

        if keyval in (GDK_j, GDK_Down):
            self._move_selection(1);  return True
        if keyval in (GDK_k, GDK_Up):
            self._move_selection(-1); return True
        if keyval in (GDK_Return, GDK_KPEnter):
            self._activate_selected(); return True
        if keyval in (GDK_Escape, GDK_q):
            self._close(); return True
        return False

    # ------------------------------------------------------------------
    # Selection
    # ------------------------------------------------------------------

    def _move_selection(self, delta: int) -> None:
        n = len(self._sessions)
        if n == 0:
            return
        old         = self._selected
        self._selected = (old + delta + n) % n
        new         = self._selected

        if old < len(self._card_boxes):
            self._card_boxes[old].remove_css_class("selected")
        if new < len(self._card_boxes):
            card = self._card_boxes[new]
            card.add_css_class("selected")
            # GTK4: grab_focus inside a ScrolledWindow scrolls it into view
            card.grab_focus()

    def _activate_selected(self) -> None:
        if not self._sessions:
            return
        session = self._sessions[self._selected]
        # hold() keeps the main loop alive after the window is destroyed,
        # so the timeout callback fires. release() in _focus_and_quit lets the app exit.
        self.hold()
        self._teardown_window()
        GLib.timeout_add(150, lambda: self._focus_and_quit(session))

    def _focus_and_quit(self, session: dict) -> bool:
        focus_session(session)
        self.release()
        return GLib.SOURCE_REMOVE

    # ------------------------------------------------------------------
    # Refresh
    # ------------------------------------------------------------------

    def _refresh(self) -> bool:
        if self._window is None:
            return GLib.SOURCE_REMOVE

        new_sessions = load_sessions()
        self._sessions = new_sessions

        # Clamp selected index
        if self._selected >= len(new_sessions):
            self._selected = max(0, len(new_sessions) - 1)

        # Rebuild card list in-place
        if self._list_box is not None:
            self._card_boxes = rebuild_session_list(
                self._list_box, new_sessions, self._selected,
            )

        return GLib.SOURCE_CONTINUE

    # ------------------------------------------------------------------
    # Close
    # ------------------------------------------------------------------

    def _teardown_window(self) -> None:
        if self._refresh_timer is not None:
            timer_id, self._refresh_timer = self._refresh_timer, None
            GLib.source_remove(timer_id)

        if self._window is not None:
            self._window.destroy()
            self._window     = None
            self._list_box   = None
            self._card_boxes = []

    def _close(self) -> None:
        self._teardown_window()
        self.quit()
