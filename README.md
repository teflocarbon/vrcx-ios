# Portal

An unofficial VRChat companion for iPhone and iPad: your friends and where they are, invites and requests, and what's been happening, on the go.

Portal connects either to your own self-hosted VRCX relay, which holds your VRChat session so your password never leaves it and can send push notifications, or straight to VRChat.

Portal isn't made or endorsed by VRChat or the VRCX team.

## Install

Portal is published unsigned. Sign it with your own Apple developer account.

Add this source to WarpSign, AltStore or SideStore, and it keeps Portal up to date:

```
https://github.com/teflocarbon/vrcx-ios/releases/download/latest/source.json
```

Or download `Portal.ipa` from the [latest release](https://github.com/teflocarbon/vrcx-ios/releases/tag/latest).

## Building

Portal is a SwiftUI app generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ios && xcodegen generate && open Portal.xcodeproj
```

`tools/screenshots.sh` builds it for the simulator and screenshots every screen in demo mode, with sample people instead of a real account.

## Licence

AGPL-3.0. See LICENSE and NOTICE.
