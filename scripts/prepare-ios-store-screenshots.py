#!/usr/bin/env python3
"""把 MIM-80 宣传图确定性转换为 App Store Connect 可上传 PNG。"""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image


BACKGROUND = (250, 247, 241)
SCENES = ("workspace", "conversation", "sessions", "settings", "mac-connection")
LOCALES = ("zh-Hans", "en-US")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipad-source", required=True, type=Path)
    parser.add_argument("--iphone-source", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    return parser.parse_args()


def rgb_image(path: Path) -> Image.Image:
    with Image.open(path) as image:
        # Simulator 原图带 alpha；Apple 不接受透明截图，统一铺到 App 的浅色背景。
        rgba = image.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (*BACKGROUND, 255))
        return Image.alpha_composite(background, rgba).convert("RGB")


def fit_to_canvas(image: Image.Image, target_size: tuple[int, int]) -> Image.Image:
    """等比缩放并只在边缘补背景，避免裁掉宣传文案或拉伸 App 界面。"""
    scale = min(target_size[0] / image.width, target_size[1] / image.height)
    resized_size = (round(image.width * scale), round(image.height * scale))
    resized = image.resize(resized_size, Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", target_size, BACKGROUND)
    offset = (
        (target_size[0] - resized.width) // 2,
        (target_size[1] - resized.height) // 2,
    )
    canvas.paste(resized, offset)
    return canvas


def prepare_ipad(source: Path) -> Image.Image:
    image = rgb_image(source)
    if image.size not in {(1086, 1448), (2064, 2752)}:
        raise ValueError(f"unexpected iPad source size {image.size}: {source}")
    return fit_to_canvas(image, (2064, 2752))


def prepare_iphone(source: Path) -> Image.Image:
    image = rgb_image(source)
    if image.size not in {(853, 1844), (1206, 2622)}:
        raise ValueError(f"unexpected iPhone source size {image.size}: {source}")
    return fit_to_canvas(image, (1242, 2688))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save(image: Image.Image, path: Path) -> dict[str, object]:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"refusing to overwrite {path}")
    image.save(path, format="PNG", optimize=True)
    return {
        "path": str(path),
        "width": image.width,
        "height": image.height,
        "mode": image.mode,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def main() -> None:
    args = parse_args()
    files: list[dict[str, object]] = []

    for locale in LOCALES:
        for index, scene in enumerate(SCENES, start=1):
            ipad_source = args.ipad_source / locale / f"{scene}.png"
            iphone_source = args.iphone_source / locale / f"{scene}.png"
            if not ipad_source.is_file() or not iphone_source.is_file():
                raise FileNotFoundError(f"missing source for {locale}/{scene}")

            ipad_name = f"ipad-13-{index:02d}-{scene}.png"
            iphone_name = f"iphone-6.5-{index:02d}-{scene}.png"
            ipad_record = save(
                prepare_ipad(ipad_source),
                args.output_root / locale / "ipad-13" / ipad_name,
            )
            iphone_record = save(
                prepare_iphone(iphone_source),
                args.output_root / locale / "iphone-6.5" / iphone_name,
            )
            ipad_record.update(locale=locale, device="ipad-13", scene=scene, order=index)
            iphone_record.update(locale=locale, device="iphone-6.5", scene=scene, order=index)
            files.extend((ipad_record, iphone_record))

    manifest = {
        "schemaVersion": 1,
        "issue": "MIM-80",
        "targetVersion": "1.1",
        "sourceCommit": args.source_commit,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "uploadReady": True,
        "containsThirdPartyBranding": True,
        "locales": list(LOCALES),
        "scenes": list(SCENES),
        "files": files,
    }
    manifest_path = args.output_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"IOS_STORE_SCREENSHOT_MANIFEST={manifest_path}")


if __name__ == "__main__":
    main()
