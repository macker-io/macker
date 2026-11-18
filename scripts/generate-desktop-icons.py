#!/usr/bin/env python3
"""Regenerate the macOS app and status-item assets from the source fish SVG."""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Macker/Assets.xcassets"
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def element(tag, **attributes):
    return ET.Element(f"{{{SVG}}}{tag}", attributes)


def catalog(directory, contents):
    directory.mkdir(exist_ok=True)
    contents["info"] = {"author": "xcode", "version": 1}
    (directory / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main():
    fish = ET.parse(ROOT / "App/Artwork/MackerFish.svg").getroot()
    assets = {"MenuFishIdle": (False, False), "MenuFishIdleBlink": (False, True),
              "MenuFishRunning": (True, False), "MenuFishRunningBlink": (True, True)}
    for name, (running, blinking) in assets.items():
        glyph = copy.deepcopy(fish)
        glyph.attrib.update({"viewBox": "1 4 22 16", "width": "22", "height": "16", "stroke": "#000000"})
        stripe, eye = list(glyph)[-2:]
        if not running:
            stripe.set("opacity", "0.55")
        eye.set("fill", "#000000")
        if blinking:
            glyph.remove(eye)
            glyph.append(element("path", d="M16.25 11 h2.2", **{"stroke-width": "1.2"}))
        directory = ASSETS / f"{name}.imageset"
        catalog(directory, {"images": [{"idiom": "mac", "filename": "Fish.svg"}], "properties": {
            "preserves-vector-representation": True, "template-rendering-intent": "template",
        }})
        svg = ET.tostring(glyph, encoding="unicode")
        (directory / "Fish.svg").write_text("\n".join(line.rstrip() for line in svg.splitlines()) + "\n")

    # Render only the transparent motif. Icon Composer owns the background,
    # shape, and appearance adaptations. A raster foreground preserves the
    # hollow outline across dark renditions.
    layer = ASSETS.parent / "AppIcon.icon" / "Assets" / "Fish.png"
    layer.parent.mkdir(parents=True, exist_ok=True)
    silver = "#E4FAFD"
    fish.attrib.update({"viewBox": "-3.5 -3.5 31 31", "width": "1024", "height": "1024", "stroke": silver})
    fish[-1].set("fill", silver)
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "Fish.svg"
        source.write_text(ET.tostring(fish, encoding="unicode"))
        subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(source), "--out", str(layer)],
                       check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
