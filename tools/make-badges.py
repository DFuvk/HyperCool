#!/usr/bin/env python3
"""Refresh the rounded README badges (docs/badges/*.svg).

The badges are drawn by shields.io in the "for-the-badge" style (exactly
the look used in README.md) and only two things are changed here: the two
background rectangles get a rounded clip path, and crispEdges is replaced so
the corners are anti-aliased. Everything else (values, logos, colours, fonts)
stays whatever shields.io returns, so the badge content is always current.

Run it by hand after a release, or let .github/workflows/badges.yml do it
daily, on every release, and on demand. A badge that cannot be fetched is left
untouched.
"""

import pathlib
import re
import sys
import urllib.error
import urllib.request

REPO = "yudharn/HyperCool"
OUT = pathlib.Path("docs/badges")
RADIUS = 6  # corner radius in px for the 28px tall for-the-badge style

BADGES = {
    "downloads": (
        "https://img.shields.io/github/downloads/%s/total"
        "?style=for-the-badge&label=downloads&labelColor=2d333b&color=3d444d"
        "&logo=github&logoColor=white" % REPO
    ),
    "stars": (
        "https://img.shields.io/github/stars/%s"
        "?style=for-the-badge&label=stars&labelColor=2d333b&color=3d444d"
        "&logo=github&logoColor=white" % REPO
    ),
    "android": (
        "https://img.shields.io/badge/Android-11%2B-3d444d"
        "?style=for-the-badge&labelColor=2d333b&logo=android&logoColor=3ddc84"
    ),
    "release": (
        "https://img.shields.io/github/v/release/%s"
        "?style=for-the-badge&label=release&labelColor=2d333b&color=3d444d"
        "&logo=github&logoColor=white" % REPO
    ),
    "telegram": (
        "https://img.shields.io/badge/Telegram-%40ModuleArchives-229ED9"
        "?style=for-the-badge&labelColor=229ED9&color=229ED9"
        "&logo=telegram&logoColor=white"
    ),
}


def rounded(svg: str, radius: int) -> str:
    """Give the badge background rounded corners, keeping the shields layout."""
    size = re.search(r'<svg[^>]*\bwidth="([0-9.]+)"[^>]*\bheight="([0-9.]+)"', svg)
    if not size:
        raise ValueError("could not read the badge size")
    width, height = size.group(1), size.group(2)

    # anti-aliased curves instead of pixel-snapped rectangles
    svg = svg.replace(
        '<g shape-rendering="crispEdges">',
        '<defs><clipPath id="hc-round">'
        '<rect width="%s" height="%s" rx="%d"/>'
        "</clipPath></defs>"
        '<g clip-path="url(#hc-round)" shape-rendering="geometricPrecision">'
        % (width, height, radius),
        1,
    )
    return svg


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "hypercool-badges"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    written = 0
    failed = 0
    for name, url in BADGES.items():
        try:
            svg = rounded(fetch(url), RADIUS)
        except (urllib.error.URLError, OSError, ValueError) as exc:
            print("skip %s: %s" % (name, exc), file=sys.stderr)
            failed += 1
            continue
        (OUT / (name + ".svg")).write_text(svg, encoding="utf-8")
        written += 1
        print("wrote %s.svg" % name)
    if not written:
        print("no badge could be refreshed", file=sys.stderr)
        return 1
    if failed:
        print("%d badge(s) left untouched" % failed, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
