#!/usr/bin/env python3
"""Bundle a pinned Rain120 dependency and a portable Node runtime; no Go services."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local"
COMMIT = "9aaf39d7699e7affd907cb902afa548b1e0be50c"
UPSTREAM_SHA = "a8b711dca5b610bfa6d0d9935273c718fcbbd27f1cbfd80822c48a238faacf15"
NODE_VERSION = "24.22.3"
OUTPUT = LOCAL / "build/mac-qq-runtime"


def download(url, target):
    if target.is_file():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as destination:
        temporary = Path(destination.name)
        try:
            with urllib.request.urlopen(url, timeout=120) as source:
                shutil.copyfileobj(source, destination)
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)


def prepare():
    arch = {"arm64": "arm64", "x86_64": "x64"}[platform.machine()]
    patch_files = sorted((ROOT / "QQMusicRuntime/upstream").glob("*"))
    local_files = sorted(p for p in (ROOT / "QQMusicRuntime").iterdir() if p.is_file())
    stamp = {"commit": COMMIT, "node": NODE_VERSION, "arch": arch,
             "patches": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [*patch_files, *local_files, Path(__file__)] if path.is_file()}}
    manifest = OUTPUT / "runtime.json"
    if manifest.is_file() and json.loads(manifest.read_text()) == stamp:
        print("QQ Music runtime is ready inside .local/build/mac-qq-runtime")
        return
    cache = LOCAL / "cache/mac-qq-runtime"
    cache.mkdir(parents=True, exist_ok=True)
    node_file = f"node-v{NODE_VERSION}-darwin-{arch}.tar.gz"
    base = f"https://nodejs.org/dist/v{NODE_VERSION}/"
    checksums = cache / f"node-v{NODE_VERSION}-SHASUMS256.txt"
    download(base + "SHASUMS256.txt", checksums)
    expected = next(line.split()[0] for line in checksums.read_text().splitlines() if line.split()[-1] == node_file)
    node_archive = cache / node_file
    download(base + node_file, node_archive)
    if hashlib.sha256(node_archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError("Node archive checksum mismatch")
    qq_archive = cache / f"qq-{COMMIT}.tar.gz"
    download(f"https://codeload.github.com/Rain120/qq-music-api/tar.gz/{COMMIT}", qq_archive)
    if hashlib.sha256(qq_archive.read_bytes()).hexdigest() != UPSTREAM_SHA:
        raise RuntimeError("QQ Music API archive checksum mismatch")
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        staging = Path(temporary)
        for archive in (node_archive, qq_archive):
            subprocess.run(["/usr/bin/tar", "-xzf", archive, "-C", staging], check=True)
        node_root = staging / f"node-v{NODE_VERSION}-darwin-{arch}"
        node = node_root / "bin/node"
        source = staging / f"qq-music-api-{COMMIT}"
        env = dict(os.environ, PATH=str(node_root / "bin") + os.pathsep + os.environ.get("PATH", ""))
        subprocess.run([node, node_root / "lib/node_modules/npm/bin/npm-cli.js", "ci", "--omit=dev", "--ignore-scripts",
                        "--no-audit", "--no-fund", "--cache", LOCAL / "cache/npm"], cwd=source, env=env, check=True)
        subprocess.run([node, ROOT / "QQMusicRuntime/upstream/patch-qq.cjs", source], check=True)
        app = source / "app.js"
        text = app.read_text()
        # Stop the upstream CLI entry from spawning npm or logging queries.
        text = text.replace('require("@babel/register");', '').replace("const chalk = require('chalk');", '')
        start = text.index("console.log(chalk.green")
        end = text.index("app.use(bodyParser());", start)
        text = text[:start] + text[end:]
        text = text.replace("app.use(bodyParser());",
                            "const ippleLocal = require('./util/ipple-local.cjs');\n"
                            "app.use(ippleLocal.guard);\napp.use(ippleLocal.similarSongs);\napp.use(bodyParser());")
        start = text.index("app.listen(PORT")
        text = text[:start] + "module.exports = app;\n"
        app.write_text(text)
        # Current Node handles the upstream's CommonJS/async code natively.
        # Terminal colour decorators are logging-only; avoid bundling dev tooling.
        (source / "util/colors.js").write_text(
            "for (const name of ['silly','input','verbose','prompt','info','data','help','warn','debug','error']) "
            "Object.defineProperty(String.prototype,name,{get(){return String(this)},configurable:true});\nmodule.exports={};\n")
        for file in local_files:
            if file.is_file():
                shutil.copy2(file, source / "util" / file.name)
        (source / "routers/context/getComments.js").write_text(
            "module.exports = async ctx => { ctx.body = { response: await "
            "require('../../util/comment-media.cjs').read(require('../../module').UCommon, ctx.query) }; };\n")
        lyric = source / "util/ipple-lyrics.js"
        text = lyric.read_text()
        text = text.replace("resultBody.word_lyric = wordData.lyric;",
                            "resultBody.word_lyric = wordData.lyric; resultBody.word_lines = require('./qrc.cjs').decode(wordData.lyric);")
        lyric.write_text(text)
        prepared = staging / "runtime"
        prepared.mkdir()
        shutil.copy2(node, prepared / "node")
        shutil.copy2(node_root / "LICENSE", prepared / "NODE-LICENSE")
        shutil.copytree(source, prepared / "qq-music-api", ignore=shutil.ignore_patterns(".git", "docs", "screenshot", "scripts"))
        shutil.copy2(ROOT / "QQMusicRuntime/ipple-local.cjs", prepared / "launch.cjs")
        (prepared / "runtime.json").write_text(json.dumps(stamp, indent=2))
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.move(prepared, OUTPUT)
    print("Prepared portable Node and pinned Rain120 QQ Music API; no database server is needed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, help="application resources directory")
    args = parser.parse_args()
    LOCAL.mkdir(parents=True, exist_ok=True)
    with (LOCAL / "prepare-player.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare()
        if args.bundle:
            target = args.bundle / "QQMusicRuntime"
            stamp = OUTPUT / "runtime.json"
            if (target / "runtime.json").is_file() and (target / "node").is_file() and (target / "launch.cjs").is_file() and (target / "runtime.json").read_bytes() == stamp.read_bytes():
                return
            args.bundle.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=args.bundle) as temporary:
                replacement = Path(temporary) / "QQMusicRuntime"
                shutil.copytree(OUTPUT, replacement, symlinks=True)
                if target.exists():
                    target.rename(Path(temporary) / "previous")
                replacement.rename(target)


if __name__ == "__main__":
    main()
