#!/usr/bin/env python3
"""Generates the README banners (light + dark SVG) and the GitHub social preview.

Text is converted to outlines with fontTools, so the SVGs need no fonts and look the same everywhere.
    python3 assets/make_banner.py [path/to/JetBrainsMono fonts dir]
Needs: fontTools. The PNG is rendered with headless Firefox if it's installed.
"""
import os
import shutil
import subprocess
import sys
import tempfile

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.local/share/fonts/JetBrainsMono")
FONTS = {w: TTFont(os.path.join(FONT_DIR, f"JetBrainsMonoNLNerdFontMono-{w}.ttf")) for w in ("Regular", "Medium", "ExtraBold")}

TITLE = ("ROS ", "Manager")
TAGLINE = "Install ROS 2 on Ubuntu with one command."
SUBLINE = "Distro picker · Gazebo · MoveIt · Nav2 · SLAM · ros2_control · any ros-* package"
COMMAND = ("$ ", "bash <(wget -qO- bit.ly/ros-manager)")

# Same ramp as the installer's progress bars (RAMP_RGB): red → orange → yellow → green
RAMP = [(220, 50, 47), (245, 135, 30), (240, 200, 40), (90, 200, 90)]
THEMES = {
    "dark":  dict(bg="#0d1117", border="#30363d", fg="#e6edf3", dim="#8b949e", accent="#ff8700", pill="#161b22"),
    "light": dict(bg="#ffffff", border="#d0d7de", fg="#1f2328", dim="#59636e", accent="#d9590b", pill="#f6f8fa"),
}


def ramp(t):
    n = len(RAMP) - 1
    seg = min(int(t * n), n - 1)
    f = t * n - seg
    a, b = RAMP[seg], RAMP[seg + 1]
    return "#%02x%02x%02x" % tuple(round(a[i] + (b[i] - a[i]) * f) for i in range(3))


def text_path(s, x, y, size, weight="Regular"):
    """-> (svg path data, advance width) for s with its baseline at (x, y)"""
    font = FONTS[weight]
    gs, cmap = font.getGlyphSet(), font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    pen, cx = SVGPathPen(gs, ntos=lambda v: ("%.1f" % v).rstrip("0").rstrip(".")), x
    for ch in s:
        name = cmap.get(ord(ch), ".notdef")
        gs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, cx, y)))
        cx += gs[name].width * scale
    return pen.getCommands(), cx - x


def text(s, x, y, size, fill, weight="Regular"):
    d, w = text_path(s, x, y, size, weight)
    return f'<path fill="{fill}" d="{d}"/>', w


def dots(x, y, cell, gap):
    """the 3x3 dot grid from the splash (▄██▄ / ▀██▀ draws a clipped square), coloured along the ramp"""
    out, k = [], cell * 0.28
    for r in range(3):
        for c in range(3):
            px, py = x + c * (cell + gap), y + r * (cell + gap)
            pts = [(px + k, py), (px + cell - k, py), (px + cell, py + k), (px + cell, py + cell - k),
                   (px + cell - k, py + cell), (px + k, py + cell), (px, py + cell - k), (px, py + k)]
            out.append(f'<polygon fill="{ramp((r * 3 + c) / 8)}" points="{" ".join(f"{a:.1f},{b:.1f}" for a, b in pts)}"/>')
    return "\n".join(out)


def bar(x, y, w, h):
    """the progress bar motif: a full-width gradient strip"""
    stops = "".join(f'<stop offset="{i / (len(RAMP) - 1):.2f}" stop-color="{ramp(i / (len(RAMP) - 1))}"/>' for i in range(len(RAMP)))
    return (f'<defs><linearGradient id="ramp" x1="0" x2="1">{stops}</linearGradient></defs>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#ramp)"/>')


def pill(x, y, size, th):
    """the one-liner in a terminal-ish pill, top-left at (x, y) -> (svg, width)"""
    _, w1 = text_path(COMMAND[0], 0, 0, size); _, w2 = text_path(COMMAND[1], 0, 0, size)
    w, h = w1 + w2 + 2.4 * size, 2.6 * size
    return "\n".join([f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{h:.1f}" rx="12" fill="{th["pill"]}" stroke="{th["border"]}"/>',
                      text(COMMAND[0], x + 1.2 * size, y + 1.65 * size, size, th["accent"], "Medium")[0],
                      text(COMMAND[1], x + 1.2 * size + w1, y + 1.65 * size, size, th["fg"])[0]]), w


def banner(t, W, H, stacked=False):
    th = THEMES[t]
    rx = 0 if stacked else 24   # social previews get cropped by whoever shows them: no corners of our own
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
             f'<title>ROS Manager: install ROS 2 on Ubuntu with one command</title>',
             f'<clipPath id="card"><rect width="{W}" height="{H}" rx="{rx}"/></clipPath>',
             f'<g clip-path="url(#card)">',
             f'<rect width="{W}" height="{H}" fill="{th["bg"]}"/>',
             bar(0, H - 8, W, 8), '</g>',
             f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="{rx}" fill="none" stroke="{th["border"]}"/>' if rx else ""]

    if stacked:   # social preview: grid on top, everything centred
        cell, gap = 52, 18
        grid = cell * 3 + gap * 2
        top = (H - 8 - (grid + 100 + 140 + 2.6 * 22)) / 2   # grid, title, tagline, subline, pill
        parts.append(dots((W - grid) / 2, top, cell, gap))
        y = top + grid + 100
        _, w1 = text_path(TITLE[0], 0, 0, 84, "ExtraBold"); _, w2 = text_path(TITLE[1], 0, 0, 84, "ExtraBold")
        x = (W - w1 - w2) / 2
        p, w = text(TITLE[0], x, y, 84, th["fg"], "ExtraBold"); parts.append(p)
        p, _ = text(TITLE[1], x + w, y, 84, th["accent"], "ExtraBold"); parts.append(p)
        _, w = text_path(TAGLINE, 0, 0, 30, "Medium")
        parts.append(text(TAGLINE, (W - w) / 2, y + 62, 30, th["fg"], "Medium")[0])
        _, w = text_path(SUBLINE, 0, 0, 20)
        parts.append(text(SUBLINE, (W - w) / 2, y + 104, 20, th["dim"])[0])
        _, w = pill(0, 0, 22, th)
        parts.append(pill((W - w) / 2, y + 140, 22, th)[0])
    else:         # README banner: grid left, text right
        cell, gap = 46, 16
        grid = cell * 3 + gap * 2
        gx, gy = 80, (H - grid) / 2 - 4
        parts.append(dots(gx, gy, cell, gap))
        x = gx + grid + 72
        p, w = text(TITLE[0], x, 128, 72, th["fg"], "ExtraBold"); parts.append(p)
        p, _ = text(TITLE[1], x + w, 128, 72, th["accent"], "ExtraBold"); parts.append(p)
        parts.append(text(TAGLINE, x, 180, 26, th["fg"], "Medium")[0])
        parts.append(text(SUBLINE, x + 1, 216, 17, th["dim"])[0])
        parts.append(pill(x, 250, 20, th)[0])

    parts.append("</svg>")
    return "\n".join(parts)


def to_png(svg_path, png_path, W, H):
    firefox = shutil.which("firefox")
    if not firefox:
        print("firefox not found: skipped", png_path)
        return
    with tempfile.TemporaryDirectory(dir=HERE) as prof:   # under the repo: snap Firefox can't read /tmp
        html = os.path.join(prof, "page.html")
        with open(html, "w") as f:
            f.write(f'<html><body style="margin:0;background:transparent"><img src="file://{svg_path}" width="{W}" height="{H}"></body></html>')
        subprocess.run([firefox, "--headless", "--no-remote", "--profile", prof, "--window-size", f"{W},{H}",
                        "--screenshot", png_path, f"file://{html}"], check=True, capture_output=True, timeout=120)
    print("wrote", png_path)


if __name__ == "__main__":
    for t in THEMES:
        path = os.path.join(HERE, f"banner-{t}.svg")
        with open(path, "w") as f:
            f.write(banner(t, 1280, 360))
        print("wrote", path)
    social = os.path.join(HERE, "social-preview.svg")
    with open(social, "w") as f:
        f.write(banner("dark", 1280, 640, stacked=True))
    print("wrote", social)
    to_png(social, os.path.join(HERE, "social-preview.png"), 1280, 640)
    for t in THEMES:   # PNG copies for places that don't take SVG (slides, chat, docs)
        to_png(os.path.join(HERE, f"banner-{t}.svg"), os.path.join(HERE, f"banner-{t}.png"), 1280, 360)
