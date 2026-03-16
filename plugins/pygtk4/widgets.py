"""
GTK4 widget builders: header, session cards, footer, and the full picker content.
All functions return Gtk.Widget instances; no application state is stored here.
"""

# GTK4 Layer Shell must be loaded before GI imports
from ctypes import CDLL
CDLL("libgtk4-layer-shell.so")

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk


# ---------------------------------------------------------------------------
# Status dot (● N)
# ---------------------------------------------------------------------------

def build_status_dot(color: str, count: int) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=3)

    dot = Gtk.Label(label="●")
    dot.add_css_class("dot-icon")
    dot.set_css_classes(["dot-icon"])
    dot.set_markup(f'<span color="{color}">●</span>')

    cnt = Gtk.Label(label=str(count))
    cnt.add_css_class("dot-count")
    cnt.set_markup(f'<span color="{color}">{count}</span>')

    box.append(dot)
    box.append(cnt)
    return box


# ---------------------------------------------------------------------------
# Header: "cctop" title + colored dot summary
# ---------------------------------------------------------------------------

def build_header(sessions: list[dict]) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    box.add_css_class("picker-header")
    box.set_hexpand(True)

    title = Gtk.Label(label="cctop")
    title.add_css_class("header-title")
    box.append(title)

    # Spacer
    spacer = Gtk.Box()
    spacer.set_hexpand(True)
    box.append(spacer)

    # Dot counts per status group
    perm    = sum(1 for s in sessions if s.get("status") == "waiting_permission")
    attn    = sum(1 for s in sessions if s.get("status") in ("waiting_input", "needs_attention"))
    working = sum(1 for s in sessions if s.get("status") in ("working", "compacting"))
    idle    = sum(1 for s in sessions if s.get("status") == "idle")

    dots_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
    if perm:    dots_box.append(build_status_dot("#f38ba8", perm))
    if attn:    dots_box.append(build_status_dot("#f9e2af", attn))
    if working: dots_box.append(build_status_dot("#a6e3a1", working))
    if idle:    dots_box.append(build_status_dot("#6c7086", idle))

    box.append(dots_box)
    return box


# ---------------------------------------------------------------------------
# Session card
# ---------------------------------------------------------------------------

def build_session_card(session: dict, selected: bool = False) -> Gtk.Box:
    card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
    card.add_css_class("session-card")
    if selected:
        card.add_css_class("selected")
    card.set_hexpand(True)
    card.set_focusable(True)

    # Accent bar (4px colored strip on the left)
    accent = Gtk.Box()
    accent.add_css_class("accent-bar")
    accent.set_size_request(4, -1)
    accent.set_vexpand(True)
    color = session.get("status_color", "#6c7086")
    accent.set_css_classes(["accent-bar"])
    accent_css = Gtk.CssProvider()
    accent_css.load_from_string(f".accent-bar {{ background-color: {color}; }}")
    accent.get_style_context().add_provider(accent_css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    card.append(accent)

    # Card body
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    body.add_css_class("card-body")
    body.set_hexpand(True)
    body.set_margin_start(10)
    body.set_margin_end(10)
    body.set_margin_top(8)
    body.set_margin_bottom(8)

    # Row 1: name + agents + source | status
    row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
    row1.set_hexpand(True)

    name_label = Gtk.Label(label="")
    name_label.add_css_class("card-name")
    name_label.set_xalign(0.0)
    name_label.set_markup(f"<b>{_esc(session.get('display_name', ''))}</b>")
    row1.append(name_label)

    agent_count = session.get("subagent_count", 0)
    if agent_count > 0:
        agents_label = Gtk.Label(label=f"  +{agent_count}")
        agents_label.add_css_class("card-agents")
        agents_label.set_xalign(0.0)
        row1.append(agents_label)

    src_color = session.get("source_color", "#f9e2af")
    src_label = Gtk.Label(label="")
    src_label.add_css_class("card-source")
    src_label.set_xalign(0.0)
    src_label.set_markup(
        f'  <span color="{src_color}">{_esc(session.get("source_label", "CC"))}</span>'
    )
    row1.append(src_label)

    # Right-align status + time
    right_col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    right_col.set_halign(Gtk.Align.END)
    right_col.set_hexpand(True)

    status_color = session.get("status_color", "#6c7086")
    status_label = Gtk.Label(label="")
    status_label.add_css_class("card-status")
    status_label.set_markup(
        f'<span color="{status_color}">{_esc(session.get("status_label", ""))}</span>'
    )
    right_col.append(status_label)

    time_label = Gtk.Label(label="")
    time_label.add_css_class("card-time")
    time_label.set_markup(
        f'<span color="#6c7086">{_esc(session.get("relative_time", ""))}</span>'
    )
    right_col.append(time_label)

    row1.append(right_col)
    body.append(row1)

    # Row 2: branch / context
    branch     = session.get("branch") or ""
    ctx        = session.get("context_line")
    row2_text  = branch
    if ctx:
        row2_text += f"  /  {ctx}"

    if row2_text:
        row2 = Gtk.Label(label="")
        row2.add_css_class("card-context")
        row2.set_xalign(0.0)
        row2.set_ellipsize(3)  # PANGO_ELLIPSIZE_END
        row2.set_markup(f'<span color="#a6adc8">{_esc(row2_text)}</span>')
        body.append(row2)

    card.append(body)
    return card


# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------

def build_footer() -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
    box.add_css_class("picker-footer")
    box.set_hexpand(True)

    hint = Gtk.Label(label="")
    hint.add_css_class("footer-hint")
    hint.set_markup(
        '<span color="#6c7086">j/k  navigate    enter  focus    esc  close</span>'
    )
    hint.set_halign(Gtk.Align.CENTER)
    hint.set_hexpand(True)
    box.append(hint)
    return box


# ---------------------------------------------------------------------------
# Full picker content
# ---------------------------------------------------------------------------

def build_picker_content(
    sessions: list[dict],
    selected_index: int,
) -> tuple[Gtk.Box, list[Gtk.Box]]:
    """
    Build the full picker container.
    Returns (container_box, card_boxes) where card_boxes[i] is the i-th session card.
    """
    container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    container.add_css_class("picker-container")
    container.set_size_request(700, -1)

    # Header
    container.append(build_header(sessions))
    container.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

    # Session list in a scrolled window
    scrolled = Gtk.ScrolledWindow()
    scrolled.add_css_class("picker-scroll")
    scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scrolled.set_max_content_height(420)
    scrolled.set_propagate_natural_height(True)

    list_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    list_box.set_hexpand(True)

    card_boxes: list[Gtk.Box] = []
    if sessions:
        for i, session in enumerate(sessions):
            card = build_session_card(session, selected=(i == selected_index))
            list_box.append(card)
            card_boxes.append(card)
    else:
        empty = Gtk.Label(label="No active sessions")
        empty.set_margin_top(24)
        empty.set_margin_bottom(24)
        empty.set_halign(Gtk.Align.CENTER)
        list_box.append(empty)

    scrolled.set_child(list_box)
    container.append(scrolled)
    container.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))

    # Footer
    container.append(build_footer())

    return container, card_boxes


# ---------------------------------------------------------------------------
# In-place session list rebuild (for refresh)
# ---------------------------------------------------------------------------

def rebuild_session_list(
    list_box:       Gtk.Box,
    sessions:       list[dict],
    selected_index: int,
) -> list[Gtk.Box]:
    """
    Clear list_box and repopulate with new session cards.
    Returns the new card_boxes list.
    """
    # Remove all existing children
    child = list_box.get_first_child()
    while child:
        nxt = child.get_next_sibling()
        list_box.remove(child)
        child = nxt

    card_boxes: list[Gtk.Box] = []
    if sessions:
        for i, session in enumerate(sessions):
            card = build_session_card(session, selected=(i == selected_index))
            list_box.append(card)
            card_boxes.append(card)
    else:
        empty = Gtk.Label(label="No active sessions")
        empty.set_margin_top(24)
        empty.set_margin_bottom(24)
        empty.set_halign(Gtk.Align.CENTER)
        list_box.append(empty)

    return card_boxes


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _esc(s: str) -> str:
    """Escape string for Pango markup."""
    return (
        str(s)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
