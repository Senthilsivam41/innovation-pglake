from pathlib import Path
import os
import re
import shutil


ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
SOURCE = ROOT / "demo-ui"
API_BASE_URL = os.getenv("API_BASE_URL", "").rstrip("/")


def render_template(text: str) -> str:
    replacements = {
        "{{ bucket }}": os.getenv("S3_BUCKET", "atherlake"),
        "{{ prefix }}": os.getenv("S3_PREFIX", "warehouse"),
        "{{ minio_console }}": os.getenv("MINIO_CONSOLE_URL", "#"),
        "{{ api_base_url }}": API_BASE_URL,
        "{{ url_for('static', filename='styles.css') }}": "./static/styles.css",
        "{{ url_for('static', filename='app.js') }}": "./static/app.js",
    }
    for source, target in replacements.items():
        text = text.replace(source, target)
    return text


def main() -> None:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir()
    (DIST / "static").mkdir()

    (DIST / "index.html").write_text(render_template((SOURCE / "templates" / "index.html").read_text()), encoding="utf-8")
    for filename in ("app.js", "styles.css"):
        shutil.copy2(SOURCE / "static" / filename, DIST / "static" / filename)

    if API_BASE_URL:
        (DIST / "api-base-url.txt").write_text(API_BASE_URL, encoding="utf-8")


if __name__ == "__main__":
    main()
