# Portal (vrcx-ios)

Portal is an unofficial VRChat companion for iPhone and iPad. It talks either to the owner's self-hosted VRCX relay (a pass-through that holds one VRChat session, records events and sends push notifications) or straight to VRChat. The app is SwiftUI under `ios/` (XcodeGen: `ios/project.yml` is the source of truth; the `.xcodeproj` is generated and never committed). `tools/` holds the icon generator, the AltStore source writer and the screenshot script.

Its design follows Teflokit's wrist UI (a visionOS-like glass VRCX view in VR), mapped onto iOS: Liquid Glass on iOS 26+ for controls, plain inset-grouped lists for content.

## This repository is public

Everything that lands here is public and effectively permanent: code, fixtures, docs, commit messages, issues and pull requests, CI logs, and release assets. Deleting something in a later commit doesn't remove it: it stays in the history, in forks and in caches. Assume anything you write may be read by anyone, and work accordingly.

**Never commit, paste into a commit message, issue or PR, or print in CI:**

- VRChat credentials: usernames, passwords, two-factor codes and recovery codes.
- Sessions: the `auth` and `twoFactorAuth` cookies, pipeline tickets, the relay's `vrcx_relay_session` cookie, relay logins and passwords, admin page sessions.
- Push secrets: APNs `.p8` keys, key IDs and team IDs, and device tokens.
- The relay's address: tailnet hostnames, IPs, its `RELAY_SECRET_KEY`.
- Real VRChat IDs: user, world, avatar, group and file IDs (`usr_…`, `wrld_…`, `avtr_…`, `grp_…`, `file_…`), and instance strings, which carry nonces.
- Anything that identifies a real person: display names, bios, status messages, friends lists, location history, notes.
- API responses, pipeline events or network logs from a real account, even redacted ones, without reading every line first.
- Signed IPAs, and screenshots that show any of the above. Use demo mode (`-demo -demoScreen <name>`) for screenshots.

**Data from a real account** (fixtures, test cases, log excerpts in docs or commits) is scrubbed before it's committed: IDs become obviously fake ones (`usr_00000000-0000-0000-0000-000000000000`), people become `Test User`, worlds become `Test World`, and you read the diff. Describe what was seen ("seen on a device in October 2026"), not whose device or account.

**Before every commit**, read the staged diff (`git diff --cached`), not just the file list. `.gitignore` refuses the riskiest file types, but it's a safety net, not a check.

**If something sensitive is committed anyway**, a follow-up commit doesn't undo it. Tell the owner straight away, and treat the secret as exposed: sign the VRChat session out and change the password, remove the relay login, revoke the APNs key. Rewriting published history needs the owner's go-ahead.

**CI runs on public runners, with public logs.** Secrets only ever come from GitHub Secrets, are never echoed (no `set -x` near them), and workflows don't run code from forks with access to them (no `pull_request_target` with a checkout of the PR). Releases publish unsigned builds only.

## VRChat

- The VRChat API is unofficial and undocumented by VRChat; the community's vrchatapi docs and OpenAPI spec are the reference. Send a descriptive `User-Agent` naming Portal and a contact.
- Respect rate limits: back off on 429, cache worlds and users, never poll in a tight loop.
- Nothing acts for the user unattended: no auto-accepting invites, no bots. Every action is one the user taps.

## Authorship and licensing

- Commits are authored by `teflocarbon <41776153+teflocarbon@users.noreply.github.com>` (the noreply address, never a personal one) and committed by Claude (`noreply@anthropic.com`): `git commit --author="teflocarbon <41776153+teflocarbon@users.noreply.github.com>"`. No model names or IDs in anything pushed.
- Commit subjects read `Area: what changed, in plain words`, with a body explaining the problem and the fix in prose.
- The project is AGPL-3.0 (LICENSE). Ideas and approaches from other projects are fine; code copied or closely followed from one needs a compatible licence (MIT, Apache-2.0, BSD, GPL-3.0, AGPL-3.0) and a credit in NOTICE. VRCX (MIT) is credited there for the rules Portal follows from it.

## Versions

`MARKETING_VERSION` in `ios/project.yml` goes up as work lands, so a build number never stands alone: the minor version for a set of features (0.6.0), the patch for fixes and polish (0.6.1). Bump it in the commit that finishes the work, before triggering the IPA build. CI sets the build number from the run number and the commit from the SHA; Portal shows all three in You → About.

## Checks

There's no Swift compiler outside macOS. Swift is proven by building on the owner's Mac (`cd ios && xcodegen generate && xcodebuild …`, or `tools/screenshots.sh`) or by `.github/workflows/ipa.yml`, which is manual: trigger it after pushing, read the log for `error:` if it fails, and fix it without waiting to be asked.
