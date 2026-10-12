"""Write Portal's AltStore-format source, for the latest release.

    python3 tools/portal_source.py Portal.ipa notes.txt source.json

Run by .github/workflows/ipa.yml after building. The version, build,
bundle ID and minimum iOS come from the IPA's Info.plist, so the source
always matches the IPA it points at; notes.txt holds the release notes
(one change per line). The download URL is the latest release's
Portal.ipa, replaced by every build, so the source lists one version.
Add https://github.com/<repo>/releases/download/latest/source.json to
WarpSign, AltStore or SideStore and it keeps Portal up to date.
"""
import datetime
import json
import os
import plistlib
import re
import sys
import zipfile

ipa, notes_file, output = sys.argv[1:4]
repo = os.environ.get("GITHUB_REPOSITORY", "teflocarbon/vrcx-ios")
sha = os.environ.get("GITHUB_SHA", "main")
tint = "#2F7FD0"

with zipfile.ZipFile(ipa) as archive:
    name = next(n for n in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
    info = plistlib.loads(archive.read(name))

with open(notes_file, encoding="utf-8") as f:
    lines = [line.strip() for line in f if line.strip()]
notes = "\n".join(f"- {line}" for line in lines) or "Build from main."

icon = f"https://raw.githubusercontent.com/{repo}/{sha}/ios/Portal/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
version = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": info["CFBundleVersion"],
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": f"https://github.com/{repo}/releases/download/latest/Portal.ipa",
    "size": os.path.getsize(ipa),
}
if "MinimumOSVersion" in info:
    version["minOSVersion"] = info["MinimumOSVersion"]

source = {
    "name": "Portal",
    "identifier": f"io.github.{repo.replace('/', '.')}",
    "subtitle": "Portal's own builds",
    "description": "Every build of Portal from GitHub, unsigned. Sign it with your own developer account.",
    "iconURL": icon,
    "website": f"https://github.com/{repo}",
    "tintColor": tint,
    "featuredApps": [info["CFBundleIdentifier"]],
    "apps": [
        {
            "name": "Portal",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": repo.split("/")[0],
            "subtitle": "Your VRChat friends, through your own VRCX relay",
            "localizedDescription": (
                "An unofficial VRChat companion for iPhone. Portal connects to your own VRCX relay, "
                "so it sees your friends, invites and notifications without your VRChat password."
            ),
            "iconURL": icon,
            "tintColor": tint,
            "category": "social",
            "versions": [version],
        }
    ],
}
with open(output, "w", encoding="utf-8") as f:
    f.write(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
print(f"{output}: Portal {version['version']} ({version['buildVersion']})")
