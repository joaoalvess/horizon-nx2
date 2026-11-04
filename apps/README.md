# HorizonHub and HorizonTV

The two apps that put HorizonNX2's games on the TV. HorizonNX2 (the emulator, `dm/` at the repository root) runs the game on the Mac and encodes its frames; it has no network code. HorizonHub runs on the Mac, opens and closes the games and carries their stream over the home network; HorizonTV plays it on an Apple TV and sends the controller back.

```
 Apple TV                    Mac
 HorizonTV  ⇄  Wi-Fi  ⇄  HorizonHub  ⇄  local socket (DM_STREAM)  ⇄  dmhost (HorizonNX2), one per game
```

- **HorizonHub** (macOS menu bar app): the game catalog and the profiles on the Hangar SSD, opening a game with the profile's save and nick, one game at a time under the guard's `boot.lock`, closing it on a GPU error or critical memory, pairing TVs, and the bridge between dmhost's socket and the network (encryption, forward error correction, clock sync). It forwards bytes and never touches a pixel.
- **HorizonTV** (tvOS app): finds the hub over Bonjour, pairs with a code, lists the profiles and games, decodes the video, plays the sound and sends the controller.

## Layout

| Path | What |
|---|---|
| `Sources/HorizonLink` | the hub ⇄ TV protocol, on macOS and tvOS: pairing (Noise), control messages, video shards with Reed-Solomon, audio, controller, clock; also dmhost's socket protocol (`DMStream.swift`, mirroring [`dm/host/stream_proto.h`](../dm/host/stream_proto.h)) |
| `Sources/HorizonPlayer` | video decoding, audio playback and frame logs, on macOS and tvOS |
| `Sources/HubKit` | the hub's logic: catalog, sessions, guard state, the socket and network bridge, the pairing store |
| `Sources/horizon-receiver` | a receiver for the Mac that stands in for the TV in tests |
| `Sources/horizon-fakestream` | a source that stands in for dmhost: re-encodes a `.h264` recording with the hardware encoder |
| `HorizonHub/` | the Mac app |
| `HorizonTV/` | the tvOS app |
| `Tests/` | `HorizonLinkTests`, `HorizonPlayerTests`, `HubKitTests` |
| [`LINK.md`](LINK.md) | the hub ⇄ TV protocol |

The dmhost side of the stream is described in [STREAMING.md](../STREAMING.md). Each contract has a stand-in for the other end: `dm/tools/stream_probe` for the hub, `horizon-fakestream` for dmhost, `horizon-receiver` for the TV.

## Build and test

Requirements: Xcode 27.2 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
cd apps
swift build
swift test
```

With the Hangar SSD mounted, one `HubKitTests` test also runs the guard (`/Volumes/Hangar/Games/overnight/guard.py`) on a state folder of its own; `HorizonPlayerTests` need the Mac's hardware HEVC decoder.

The apps are built from an Xcode project that XcodeGen writes from [`project.yml`](project.yml):

```
xcodegen generate
xcodebuild -project Horizon.xcodeproj -scheme HorizonHub -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
xcodebuild -project Horizon.xcodeproj -scheme HorizonTV -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build
```

Xcode's `appintentsmetadataprocessor` prints `warning: Metadata extraction skipped, no AppIntents.framework dependency found` for both apps; it is a note from that tool, not a compiler warning.

Signing stays out of the repository: copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` (ignored by git) and put your team ID in it. A fixed team keeps the app's signature stable between builds, so macOS keeps its Local Network and removable-volume permissions and its keychain access.

## Install and first start

1. `scripts/install_hub.sh` builds HorizonHub in Release, quits the running one, installs it in `~/Applications` and opens it.
2. Store the Hangar SSD's password for the hub, trusted by the app so it unlocks the SSD without asking:

   ```
   security add-generic-password -s dev.joaoalvess.horizon.hub -a ssd-hangar -l "HorizonHub: Hangar SSD" -T ~/Applications/HorizonHub.app -w
   ```

3. Accept the Local Network prompt, and the removable-volume prompt when the game list loads from the SSD.
4. Install HorizonTV on the Apple TV from Xcode (scheme HorizonTV, the Apple TV as destination), then pair it: HorizonHub › TV › Pair a TV…, and type the code the TV shows. The hub has a new identity, so a TV paired with an earlier hub pairs again.
5. Turn on Open at Login in the menu bar menu once the app sits in `~/Applications`.

HorizonHub keeps its settings and paired TVs in `~/Library/Application Support/HorizonHub`, its identity in the keychain (service `dev.joaoalvess.horizon.hub`), and reads the catalog from `/Volumes/Hangar/Games/hangar-games.json` (`HORIZON_GAMES_CATALOG` names another).

## Status

| Stage | Acceptance | State |
|---|---|---|
| M1 import | `swift build` and `swift test` pass with the 153 tests; XcodeGen writes the project; both apps build unsigned with no warnings | done (2026-11-04): 153 tests pass (HubKit 49, HorizonPlayer 19, HorizonLink 85); both apps build unsigned with no compiler warning |
| M2 HorizonHub as its own app | menu bar, Open at Login, single instance, closing the game on quit, games window, TV section; builds and tests pass | done (2026-11-04): builds and tests pass; first run on the Mac waits for the install (see [Install and first start](#install-and-first-start)) |
| M3 HorizonTV | new name and identity; builds for the tvOS Simulator with no warnings | done (2026-11-04) |
| M4 repository | `.gitignore`, `dm/tools/impact_map.tsv`, `scripts/install_hub.sh`, `horizon-fakestream` against `stream_probe` with no decode error and no gap | done (2026-11-04): `install_hub.sh` written, not run; 40 s of `dk_s2_play.h264` through `stream_probe`: 2,358 frames at 58.9 fps, 0 decode errors, 0 frame-number gaps, 0 audio gaps, 0 protocol errors |
| M5 docs | this page, STREAMING.md, the README's streaming section, CLAUDE.md, `test_docs.py` | done (2026-11-04): `test_docs.py`, `test_usage.py` and `test_ci_toolchain.py` pass |

Imported from the earlier hub's repository at commit `c59355e`, renamed and translated to English.
