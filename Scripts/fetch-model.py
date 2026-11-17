"""Install only the pinned inference assets, verifying LFS SHA256 or Git blob IDs."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import sys

manifest = json.loads(Path(__file__).with_name("model-files.json").read_text())
root = Path(sys.argv[1])
base = "https://huggingface.co/FluidInference/CosyVoice3-0.5B-coreml/resolve/" + manifest["revision"]


def fetch(entry):
    target = root / entry["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                    "--retry", "4", "--output", str(target), base + "/" + entry["path"]], check=True)
    digest = hashlib.sha256() if len(entry["digest"]) == 64 else hashlib.sha1()
    if digest.name == "sha1":
        digest.update(f"blob {entry['size']}\0".encode())
    with target.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if target.stat().st_size != entry["size"] or digest.hexdigest() != entry["digest"]:
        raise ValueError(f"Model integrity check failed: {target}")
    print(f"Verified {entry['path']}", flush=True)


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch, manifest["files"]))
