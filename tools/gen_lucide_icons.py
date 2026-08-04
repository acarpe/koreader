#!/usr/bin/env python3

"""Generate resources/icons/lucide from the upstream lucide-static package.

Icons that have a real Lucide counterpart are copied over verbatim (only the
root element is rewritten, see normalize()). The ~45 KOReader-specific icons
(dogear, direction, rotation, cre.render, zoom, position.marker, ...) have no
counterpart in any icon set and are drawn here on the Lucide grid instead:
24x24 viewBox, 2px stroke, round caps and joins, no fill.

Two deliberate deviations from the Lucide house style:

  * stroke="#000000" instead of stroke="currentColor". NanoSVG (the renderer
    KOReader uses, see frontend/ui/renderimage.lua) does not implement
    currentColor and would draw those paths black-on-black... i.e. invisible.

  * A handful of icons keep the full-bleed geometry of the icon they replace
    rather than Lucide's 2px padding, because their container decides their
    size: the dogear corner folds have to reach the corner of the page, and
    the progress bar position markers have to reach the edge of the bar.

Usage:
    python3 tools/gen_lucide_icons.py /path/to/lucide-static/icons
"""

import os
import re
import sys

LUCIDE_VERSION = "1.28.0"

# Lucide's own grey for "inactive" parts of an icon, as used by the wifi ramps.
GREY = "#999999"
# Ditto for the ".alpha" variants, which are dimmed-out copies of an icon.
DIM = "#666666"

ROOT_ATTRS = (
    'xmlns="http://www.w3.org/2000/svg" width="24" height="24"'
    ' viewBox="0 0 24 24" fill="none" stroke="#000000" stroke-width="2"'
    ' stroke-linecap="round" stroke-linejoin="round"'
)

SHAPES = r"<(path|rect|circle|ellipse|line|polyline|polygon)\b"


def recolor(body, colour):
    """Override the stroke colour of every element in an icon body."""
    return re.sub(SHAPES, r'<\1 stroke="%s"' % colour, body)


def refill(body, colour):
    """Fill every element in an icon body."""
    return re.sub(SHAPES, r'<\1 fill="%s"' % colour, body)


def rotate(body, angle):
    """Rotate an icon body around the centre of the grid."""
    if angle % 360 == 0:
        return body
    return '<g transform="rotate(%d 12 12)">%s</g>' % (angle, body)


def mirror(body):
    """Flip an icon body horizontally, for the .rtl variants."""
    return '<g transform="translate(24 0) scale(-1 1)">%s</g>' % body


def scaled(body, factor, cx, cy):
    """Shrink an icon body and centre it on (cx, cy).

    stroke-width is divided back out because both NanoSVG and librsvg scale the
    stroke along with the geometry, and we want the result to still read as a
    2px stroke next to the icon it is composed into.
    """
    return '<g transform="translate(%g %g) scale(%g)" stroke-width="%g">%s</g>' % (
        cx - 12 * factor, cy - 12 * factor, factor, 2 / factor, body)


# --------------------------------------------------------------------------
# Icons taken straight from Lucide: koreader name -> lucide name.
# --------------------------------------------------------------------------

MAPPED = {
    "align.auto":           "text-initial",
    "align.center":         "text-align-center",
    "align.justify":        "text-align-justify",
    "align.left":           "text-align-start",
    "align.right":          "text-align-end",
    "appbar.contrast":      "contrast",
    "appbar.crop":          "crop",
    "appbar.filebrowser":   "folder",
    "appbar.menu":          "menu",
    "appbar.navigation":    "book-marked",
    "appbar.pagefit":       "maximize",
    "appbar.pageview":      "file-text",
    "appbar.rotation":      "rotate-cw-square",
    "appbar.search":        "search",
    "appbar.settings":      "settings",
    "appbar.textsize":      "a-large-small",
    "appbar.tools":         "wrench",
    "appbar.typeset":       "pilcrow",
    "back.top":             "corner-left-up",
    "back.top.rtl":         "corner-right-up",
    "book.opened":          "book-open",
    "bookmark":             "bookmark",
    "cancel":               "ban",
    "check":                "check",
    "chevron.first":        "chevrons-left",
    "chevron.last":         "chevrons-right",
    "chevron.left":         "chevron-left",
    "chevron.right":        "chevron-right",
    "chevron.up":           "chevron-up",
    "close":                "x",
    "column.one":           "square",
    "column.two":           "columns-2",
    "column.three":         "columns-3",
    "control.collapse":     "chevron-down",
    "control.expand":       "chevron-right",
    "cre.render.partial":   "file-stack",
    "cre.render.ready":     "file-check",
    "cre.render.working":   "file-cog",
    "edit":                 "square-pen",
    "exit":                 "x",
    "home":                 "house",
    "info":                 "info",
    "move.down":            "arrow-down",
    "move.up":              "arrow-up",
    "notice-info":          "info",
    "notice-question":      "circle-help",
    "notice-warning":       "triangle-alert",
    "plus":                 "plus",
    "star.empty":           "star",
    "triangle":             "triangle",
    "wifi":                 "wifi",
}

# Lucide art with a tweak applied to the body. Same provenance as MAPPED.
DERIVED = {
    # The TOC "expand" chevron, dimmed.
    "control.expand.alpha": ("chevron-right", lambda b: recolor(b, DIM)),
    # Lucide has no filled star, so fill the outline we already have.
    "star.full":            ("star", lambda b: refill(b, "#000000")),
    # Opaque star, drawn over book covers to mask what is behind it.
    "star.white":           ("star", lambda b: refill(b, "#ffffff")),
}


# --------------------------------------------------------------------------
# The KOReader-specific icons.
# --------------------------------------------------------------------------

# Portrait / landscape device frame, for the rotation icons.
FRAME_P = '<rect x="5" y="2" width="14" height="20" rx="2"/>'
FRAME_L = '<rect x="2" y="5" width="20" height="14" rx="2"/>'
# Page frame, for the zoom icons.
PAGE = '<rect x="4" y="2" width="16" height="20" rx="2"/>'
# A capital "A", 8 tall and 6 wide, centred in the frames above. Shows which way
# up the page content ends up for a given rotation. Kept small enough that it
# still clears the frame once rotated a quarter turn inside the portrait one.
LETTER_A = '<path d="M9 16 12 8l3 8"/><path d="M10 14h4"/>'

# Lucide's wifi, split up so the ramps can grey out individual arcs.
# Ordered from the innermost element outwards.
WIFI_PARTS = [
    '<path d="M12 20h.01"/>',
    '<path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
    '<path d="M5 12.859a10 10 0 0 1 14 0"/>',
    '<path d="M2 8.82a15 15 0 0 1 20 0"/>',
]
# Small padlock in the bottom right corner, marking a protected network.
# Opaque so it knocks out the arc it sits on, and thinner than the house 2px
# because a 2px stroke on a 6x5 box is a blob.
WIFI_LOCK = (
    '<rect x="16" y="17" width="6" height="5" rx="1.2"'
    ' fill="#ffffff" stroke-width="1.5"/>'
    '<path d="M17.8 17v-1.2a1.2 1.2 0 0 1 2.4 0V17" stroke-width="1.5"/>'
)

# Lucide's file body with the bottom left corner left open, lifted from
# file-cog so that cre.render.reload can drop a rotate-cw into the gap exactly
# the way file-cog drops its gear there. Hanging the arrow off the corner rather
# than shrinking it into a badge inside the page is what keeps the ring from
# closing up into a blob once it is dithered down to icon size.
FILE_BODY_OPEN = (
    '<path d="M15 8a1 1 0 0 1-1-1V2a2.4 2.4 0 0 1 1.704.706l3.588'
    ' 3.588A2.4 2.4 0 0 1 20 8z"/>'
    '<path d="M20 8v12a2 2 0 0 1-2 2h-4.182"/>'
    '<path d="M4 10.592V4a2 2 0 0 1 2-2h8"/>'
)


def wifi_ramp(lit, secure):
    """Signal strength ramp: `lit` elements black, the rest greyed out."""
    parts = []
    for i, part in enumerate(reversed(WIFI_PARTS)):  # outermost arc first
        level = len(WIFI_PARTS) - i
        parts.append(part if level <= lit else recolor(part, GREY))
    if secure:
        parts.append(WIFI_LOCK)
    return "".join(parts)


CUSTOM = {
    # -- Page corner folds -------------------------------------------------
    # Full bleed: these are drawn over the corner of a page or a book cover,
    # so the fold has to actually reach the corner.
    "dogear.reading": (
        '<path d="M0 0h24v24H0z" fill="#ffffff" stroke="none"/>'
        '<path d="M1.5 22.5V1.5H22.5Z"/>'
    ),
    "dogear.complete": (
        '<path d="M1.5 22.5H22.5V1.5Z" fill="#ffffff"/>'
        '<path d="m19 14-5.5 5.5-2-2"/>'
    ),
    "dogear.abandoned": (
        '<path d="M0 0h24v24H0z" fill="#ffffff" stroke="none"/>'
        '<path d="M1.5 22.5V1.5H22.5Z"/>'
        '<path d="M5 4.5v6"/><path d="M9 4.5v6"/>'
    ),
    # The fold the reader draws on the page when the page is bookmarked. Half
    # transparent so the text underneath stays readable; ReaderDogear asks
    # IconWidget to keep the alpha layer for this one.
    "dogear.alpha": (
        '<path d="M23 23V1H1Z" fill="#ffffff" stroke="none"/>'
        '<path d="M1 1V23H23Z" fill="#ffffff" fill-opacity="0.5"/>'
    ),
    # Same fold, no fill: marks an already opened book in the file browser.
    "dogear.opaque": '<path d="M1 1V23H23"/><path d="m1 1 22 22"/>',

    # -- Progress bar markers ----------------------------------------------
    # Full bleed as well: these have to span the height of the bar.
    "position.marker": (
        '<path d="M5 0h14l-7 9Z" fill="#000000" fill-opacity="0.8"'
        ' stroke="none"/>'
        '<path d="M5 24h14l-7-9Z" fill="#000000" fill-opacity="0.8"'
        ' stroke="none"/>'
    ),
    "position.marker.top":
        '<path d="M0 0h24l-12 24Z" fill="#000000" stroke="none"/>',

    # -- Zoom modes --------------------------------------------------------
    "zoom.page": PAGE + (
        '<path d="M15.5 8.5 8.5 15.5"/>'
        '<path d="M11.5 8.5h4v4"/><path d="M12.5 15.5h-4v-4"/>'
    ),
    "zoom.content": PAGE + '<rect x="7.5" y="6" width="9" height="12" rx="1"/>',
    "zoom.column": PAGE + '<path d="M12 2v20"/>',
    "zoom.row": PAGE + '<path d="M4 12h16"/>',
    # -- Misc --------------------------------------------------------------
    "appbar.pokeball": (
        '<circle cx="12" cy="12" r="9"/>'
        '<path d="M3 12h6"/><path d="M15 12h6"/>'
        '<circle cx="12" cy="12" r="3"/><path d="M12 12h.01"/>'
    ),
    # Diagonal hatching, for the highlight style menu. Each stripe is its own
    # path because NanoSVG has no clip-path to trim them with.
    "texture-box": (
        '<rect x="3" y="3" width="18" height="18" rx="2"/>'
        '<path d="m4.5 10.5 6-6"/><path d="m4.5 16.5 12-12"/>'
        '<path d="m7.5 19.5 12-12"/><path d="m13.5 19.5 6-6"/>'
    ),
}

CUSTOM["dogear.complete.rtl"] = mirror(CUSTOM["dogear.complete"])
CUSTOM["dogear.abandoned.rtl"] = mirror(CUSTOM["dogear.abandoned"])

# Text direction: the first pair of letters is the direction the lines run in,
# the second the direction the lines stack in. One connected stroke shows both
# axes at once, and the arrowhead sits at the end of the run.
DIRECTIONS = {
    "LRTB": ("M5 5H19V12H5V19H19", "m16 16 3 3-3 3"),
    "RLTB": ("M19 5H5V12H19V19H5", "m8 16-3 3 3 3"),
    "LRBT": ("M5 19H19V12H5V5H19", "m16 2 3 3-3 3"),
    "RLBT": ("M19 19H5V12H19V5H5", "m8 2-3 3 3 3"),
    "TBLR": ("M5 5V19H12V5H19V19", "m16 16 3 3 3-3"),
    "TBRL": ("M19 5V19H12V5H5V19", "m2 16 3 3 3-3"),
    "BTLR": ("M5 19V5H12V19H19V5", "m16 8 3-3 3 3"),
    "BTRL": ("M19 19V5H12V19H5V5", "m2 8 3-3 3 3"),
}

for _name, (_path, _arrow) in DIRECTIONS.items():
    CUSTOM["direction." + _name] = '<path d="%s"/><path d="%s"/>' % (_path, _arrow)

# Screen rotation: the frame shows the shape the screen ends up in, the arrow
# points at the edge that used to be the top.
CUSTOM["rotation.0UR"] = FRAME_P + (
    '<path d="M12 16V9"/><path d="m9.5 11.5 2.5-2.5 2.5 2.5"/>')
CUSTOM["rotation.180UD"] = FRAME_P + (
    '<path d="M12 8v7"/><path d="m9.5 12.5 2.5 2.5 2.5-2.5"/>')
CUSTOM["rotation.90CW"] = FRAME_L + (
    '<path d="M9 12h6"/><path d="m12.5 9.5 2.5 2.5-2.5 2.5"/>')
CUSTOM["rotation.90CCW"] = FRAME_L + (
    '<path d="M15 12H9"/><path d="m11.5 9.5-2.5 2.5 2.5 2.5"/>')

# Page rotation within a portrait / landscape screen.
for _prefix, _frame in (("P", FRAME_P), ("L", FRAME_L)):
    for _suffix, _angle in (("0UR", 0), ("90CW", 90), ("180UD", 180), ("90CCW", 270)):
        CUSTOM["rotation.%s.%s" % (_prefix, _suffix)] = _frame + rotate(LETTER_A, _angle)

# Entries in CUSTOM that reuse Lucide geometry instead of being drawn from
# scratch, so that the licence file credits Lucide for its share: name -> source.
CUSTOM_SOURCE = {}

for _level, _lit in (("0", 0), ("25", 1), ("50", 2), ("75", 3), ("100", 4)):
    CUSTOM["wifi.open." + _level] = wifi_ramp(_lit, False)
    CUSTOM["wifi.secure." + _level] = wifi_ramp(_lit, True)
    CUSTOM_SOURCE["wifi.open." + _level] = "wifi (modified)"
    CUSTOM_SOURCE["wifi.secure." + _level] = "wifi (modified) + KOReader original"


# Part Lucide art, part drawn here, so the body can only be assembled once the
# Lucide icon it borrows from has been read: lucide name -> assemble(body).
COMPOSED = {
    "cre.render.reload": (
        "rotate-cw", lambda b: FILE_BODY_OPEN + scaled(b, 0.5, 7, 17)),
    "cre.render.reload.alpha": (
        "rotate-cw",
        lambda b: recolor(FILE_BODY_OPEN + scaled(b, 0.5, 7, 17), DIM)),
    # Percent sign from square-percent, moved onto the page frame the rest of
    # the zoom family uses in place of square-percent's own square.
    "zoom.manual": (
        "square-percent", lambda b: PAGE + re.sub(r"<rect\b[^>]*/>", "", b)),
}


# --------------------------------------------------------------------------

def read_body(lucide_dir, name):
    """Return the drawing elements of a Lucide icon, without its root element."""
    with open(os.path.join(lucide_dir, name + ".svg")) as f:
        svg = f.read()
    body = re.sub(r"(?s)^.*?<svg\b[^>]*>", "", svg)
    body = re.sub(r"(?s)</svg>\s*$", "", body)
    # Drop the CSS classes: NanoSVG has no stylesheet support, so they are dead
    # weight, and their presence would suggest the icons can be restyled.
    body = re.sub(r'\s*class="[^"]*"', "", body)
    return re.sub(r"\s+", " ", body).strip()


def normalize(body, credit):
    return "<!-- %s -->\n<svg %s>\n  %s\n</svg>\n" % (
        credit, ROOT_ATTRS, body.replace("/><", "/>\n  <"))


def write_license(out_dir, provenance):
    with open(os.path.join(out_dir, "LICENSE-ISC"), "w") as f:
        f.write(ISC)
    with open(os.path.join(out_dir, "icons-license.txt"), "w") as f:
        f.write(PROVENANCE_HEADER)
        width = max(len(name) for name, _ in provenance)
        for name, source in provenance:
            f.write("%-*s  %s\n" % (width, name, source or "(KOReader original)"))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen_lucide_icons.py /path/to/lucide-static/icons")
    lucide_dir = sys.argv[1]
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(here, "resources", "icons", "lucide")
    os.makedirs(out_dir, exist_ok=True)

    lucide_credit = "Lucide %s - ISC - https://lucide.dev" % LUCIDE_VERSION
    own_credit = "KOReader - AGPL-3.0-or-later - drawn on the Lucide grid"
    provenance = []

    for name in sorted(set(MAPPED) | set(DERIVED) | set(COMPOSED) | set(CUSTOM)):
        if name in MAPPED:
            source = MAPPED[name]
            body = read_body(lucide_dir, source)
            credit = lucide_credit
        elif name in DERIVED:
            source, tweak = DERIVED[name]
            body = tweak(read_body(lucide_dir, source))
            credit = lucide_credit
            source += " (modified)"
        elif name in COMPOSED:
            source, assemble = COMPOSED[name]
            body = assemble(read_body(lucide_dir, source))
            credit = "%s + %s" % (lucide_credit, own_credit)
            source += " + KOReader original"
        else:
            source = CUSTOM_SOURCE.get(name)
            body = CUSTOM[name]
            if source is None:
                credit = own_credit
            elif "KOReader" in source:
                credit = "%s + %s" % (lucide_credit, own_credit)
            else:
                credit = lucide_credit
        with open(os.path.join(out_dir, name + ".svg"), "w") as f:
            f.write(normalize(body, credit))
        provenance.append((name, source))

    write_license(out_dir, provenance)
    print("wrote %d icons to %s" % (len(provenance), out_dir))


ISC = """\
ISC License

Copyright (c) for portions of Lucide are held by Cole Bemis 2013-2022 as part of
Feather (MIT). All other copyright (c) for Lucide are held by Lucide Contributors
2022.

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
"""

PROVENANCE_HEADER = """\
Icons in this directory are generated by tools/gen_lucide_icons.py.

Icons listed with a Lucide name come from Lucide (https://lucide.dev), which is
ISC licensed; see LICENSE-ISC. They are unmodified apart from the root element,
which is rewritten to a fixed stroke colour because NanoSVG (the SVG renderer
KOReader uses) does not implement currentColor. Icons marked "(modified)" also
have a fill or stroke colour applied to the drawing itself.

Icons listed as "(KOReader original)" have no counterpart in Lucide or any other
icon set. They are drawn for KOReader on the Lucide grid (24x24, 2px stroke,
round caps and joins) and are licensed under the same terms as KOReader itself,
AGPL-3.0-or-later.

"""


if __name__ == "__main__":
    main()
