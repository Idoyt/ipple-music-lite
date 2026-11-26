"""Package the Release app built by make mac-package in a read-only disk image."""
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


def package(app):
    root = Path(__file__).resolve().parents[1]
    output = root / ".local/dist/mac"
    output.mkdir(parents=True, exist_ok=True)
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    executable = Path("Contents/MacOS") / info["CFBundleExecutable"]
    arch = subprocess.check_output(["xcrun", "lipo", "-archs", app / executable], text=True).strip()
    runtime = app / "Contents/Resources/QQMusicRuntime"
    subprocess.run(["xcrun", "lipo", runtime / "node", "-verify_arch", arch], check=True)
    name = f"IppleMusic-Lite-{info['CFBundleShortVersionString']}-macOS-{arch}.dmg"

    with tempfile.TemporaryDirectory(dir=output) as temp:
        contents = Path(temp) / "volume"
        contents.mkdir()
        staged = contents / app.name
        subprocess.run(["ditto", "--noextattr", app, staged], check=True)
        subprocess.run(["xcrun", "strip", "-S", "-x", staged / executable], check=True)
        binary = (staged / executable).read_bytes()
        if any((str(folder) + "/").encode() in binary for folder in (root, Path.home())):
            raise RuntimeError("The Release executable contains a local build path")
        resources = staged / "Contents/Resources"
        (resources / "LICENSE").write_bytes((root / "LICENSE").read_bytes())
        notices = (root / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        for license_path in ("upstream/qmweb-sign.LICENSE", "QRC-LICENSE"):
            bundled = Path("QQMusicRuntime/qq-music-api/util") / Path(license_path).name
            notices = notices.replace(f"(QQMusicRuntime/{license_path})", f"({bundled})")
        (resources / "THIRD_PARTY_NOTICES.md").write_text(notices, encoding="utf-8")
        subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", staged], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", staged], check=True)
        (contents / "Applications").symlink_to("/Applications")

        image = Path(temp) / name
        subprocess.run(["hdiutil", "create", "-format", "UDZO", "-fs", "HFS+", "-volname", "Ipple Music",
                        "-srcfolder", contents, image], check=True)
        subprocess.run(["hdiutil", "verify", image], check=True)
        image.replace(output / name)
    print(output / name)


if __name__ == "__main__":
    package(Path(sys.argv[1]).resolve())
