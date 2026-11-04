# Streaming a game to the Apple TV

The goal is to play the fork's games on the TV through the user's Apple TV 4K (3rd generation, 64 GB, Wi-Fi only):

- the Mac runs the game;
- a native tvOS app shows it with low latency, with sound and the controller;
- the person picks the profile and the game on the TV.

Three pieces in this repository do it:

- **HorizonNX2** (dmhost, `dm/`): runs the game, encodes each presented frame, mixes its sound and applies the controllers it is sent. It has no network code: it talks only to the hub over a local socket. Encoded video and audio go out; controller input and requests come in. Stages S1–S3 below.
- **HorizonHub** (`apps/HorizonHub`, `apps/Sources/HubKit`): the Mac app that holds the profiles and the game catalog, starts and stops dmhost under the guard's protection, and does all the networking: Bonjour, pairing, encryption, UDP with forward error correction.
- **HorizonTV** (`apps/HorizonTV`): the tvOS app. HorizonHub and HorizonTV share the protocol package `HorizonLink` and the player `HorizonPlayer`. Their layout, build and first start are in [apps/README.md](apps/README.md); the hub ⇄ TV protocol is [apps/LINK.md](apps/LINK.md).

The hub and the tvOS app were first written in another of the user's repositories (HangarVault, stages J1–J5 of its plan) and moved here on 2026-11-04 (stage M), renamed and translated to English. Mentions of HangarVault below, from before the move, mean the hub.

## Status

| # | Stage | Done when | Status |
|---|---|---|---|
| S1 | Encoder in dmhost writing a file | See "S1" below | done (2026-11-03): all three games write a file that decodes, Donkey Kong Bananza's plays in QuickTime (checked by the user); the encoder's own time p95 6.5-7.6 ms; the capture pass costs about 0.15 ms of GPU per frame; frame time p50 unchanged on the three games' A/B, p95 unchanged on Donkey Kong Bananza and Mario Kart World, Pokopia's 1.7 ms higher inside the spread of its base runs ("Found in S1" under S1); closed with the user on the 150 s runs, without the 20 min ones |
| S2 | Local socket to HangarVault, with a probe tool for the hub's end | See "S2" below | done (2026-11-03): the probe received all three games' streams, socket hop p95 0.045-0.064 ms, every recorded `.h264` decodes whole with no frame-number gap, the stereo audio covers every attached stretch; frame time unchanged (Pokopia against a base run of the same day, the other two against S1); DETACH with pause, ATTACH again and a hub that dies mid-run checked on the games ("Found in S2" under S2); commits 805fb333 (audio) and 8ba7e691 (socket, probe) |
| S3a | Pacing without the Mac display, focus arbitration between the window and the TV | See "S3" below | code done (2026-11-03): steps 1 and 3 in, unit tests pass, independent review taken; step 2 dropped with the user; commits 7538b30c (oe), 83e38af7 (stream), a5c2ea8f (window script); the boots of step 4 wait for the test round ("Test list") |
| S3b | Network controller, pause on detach | See "S3" below | code done (2026-11-04): steps 1-4 in, unit tests pass, independent review taken ("S3b plan" under S3); commits ca9248bf (hid), 7f8f3587 (oe), bdfdb569 (stream), 17d47eb3 (probe); the boots wait for the test round ("Test list") |
| J1 | Games on the Mac: catalog, profiles, opening and closing a game under the guard | Choosing a profile and a game opens it with that profile's save and nick (`fs mount save` in the profile's folder); a second game is refused; a GPU error closes the game, writes the block and shows it in the menu; Close ends with `graceful exit done` | code done in the earlier repository; the real-game checks wait for the hub and TV test round |
| J2 | Network: Bonjour, pairing, the bridge from the local socket to UDP (FEC, acknowledgements, clock ping), a Mac test receiver | Paired, the receiver on the Pro shows the game; present to decoded p95 under 25 ms over Wi-Fi; simulated loss with no visible stall | code done; the Wi-Fi measurements wait for the test round |
| J3 | tvOS app: profiles, games, opening through the hub, video and sound | On the TV, a profile opens a game on the Mac and it plays on the TV at 60 fps with sound | code done; builds for tvOS; install and checks wait for the test round |
| J4 | Controller from the Apple TV, a combination for Home, pause and reconnection | 30 playable minutes end to end; leaving through the TV's Home and coming back resumes the game | code done; checks wait for the test round |
| J5 | Polish: bit rate and resolution on screen, messages, docs | Set on reaching it | code done: resolution, rate, codec and button layout in the TV app, on-screen statistics, hub notices on the TV |
| M | The hub and the tvOS app in this repository as HorizonHub and HorizonTV (`apps/`) | See [apps/README.md](apps/README.md#status) | done on branch `monorepo` (2026-11-04): 153 tests pass, both apps build, `horizon-fakestream` through `stream_probe` with no decode error and no gap; install and first run wait for the hub and TV test round |

Order across both plans: J1 and S1 in parallel, then S2 → J2 → S3a → J3 → S3b → J4 → J5. The local socket protocol is written below before J2 starts.

Next step: the test round with the user, item by item, from "Test list" below (decided with the user, 2026-11-03). Waiting on the user's call about resuming a paused game from the Mac window.

**Done before S1 (2026-11-03):** the run scripts in the game work folders (`runs/run_pk.sh`, `runs/run_dk.sh`, `run2/run_mkw.sh`) default to the agent's own copy of the save. It is `save_agent`, cloned from the player's save at first use. A player's save is used only when `DM_SAVE` names it. The old scripts are kept as `*.bak-2026-11-03`.

**Open:** Mario Kart World's memory grows. On 2026-11-03 guard.py killed it at 696 s (`memorystatus_level 8`) and at 1706 s (swap +3105 MB). A play session through the hub needs 30 min.

**Acceptance criteria**

- **S1:**
  - Pokopia, Donkey Kong Bananza and Mario Kart World each write a file that plays in QuickTime.
  - Encode time is logged per frame, with p95 at most 9 ms at 1080p. VideoToolbox's low-latency H.264 encoder on the MacBook Air M4 has a floor of about 7 ms p50 and 8 ms p95, the same at 720p and 1080p (5 ms at 540p, 21 ms at 4K), whatever the codec, LTR or real-time options. The first plan's 4 ms is out of its reach (changed with the user, 2026-11-03).
  - The game's frame time p50 and p95 are unchanged against a run without encoding on the same route.
  - ~~Each game runs 20 min under `guard.py` with no GPU error.~~ The user closed S1 on the 150 s A/B runs (2026-11-03). The long session, the stability test AirPlay mirroring failed, is played through the hub once the socket carries the stream.
- **S2:**
  - The probe receives all three games' streams, and the socket hop p95 is under 1 ms.
  - The game's frame time is unchanged.
- **S3a:**
  - With the Mac's display asleep, or the window behind another app, the stream holds 60 fps.
  - While a client is attached, window focus changes do not pause the game.
- **S3b:**
  - Scripted input sent by the probe moves the game.
  - Detaching pauses the game, and attaching resumes it.

## Test list

One round with the user at the end, one item at a time (decided with the user, 2026-11-03). Every boot is 150 s, muted, through the guard, from a fresh copy of the agent's save, with the probe as the hub, one at a time; before the first boot HangarVault's session is asked to stop its builds and encodes, and told when the round ends. The hosts are one build for all items, `hosts/s3/dmhost` (`runs/hosts/s3` for Pokopia and Donkey Kong Bananza, `run2/hosts/s3` for Mario Kart World), built at 1994f5d6 (2026-11-04); rebuilt if more code lands before the round. Scripts: `/Volumes/Hangar/Games/overnight/stream/s3a_run.sh <game> <mode> s3` and `s3b_run.sh <game> <mode> s3`, read with `s3a_check.sh` / `s3b_check.sh <game> <mode> s3`.

| # | Item | Command | Passes when | Result |
|---|---|---|---|---|
| 0 | Unit tests and lint on the final tree | `make -C dm/host/tests run`, `make -C dm/gfx/tests check_t_stream check_t_stream_sock`, the lint | every check passes; no new lint finding in the touched files | |
| 1 | S3a, Pokopia, window covered 40-55 s, app hidden 60-75 s | `s3a_run.sh pk seq s3` | probe fps at least 59.5 in every 5 s window; no `oe focus state` line while attached; `present pacing` says the host's clock paces | |
| 2 | S3a, Mario Kart World, the same | `s3a_run.sh mkw seq s3` | as 1 | |
| 3 | S3a, Donkey Kong Bananza, the same | `s3a_run.sh dk seq s3` | as 1, but for the route's own loads (30-45 fps in S2 too) | |
| 4 | S3a, Pokopia, no window changes | `s3a_run.sh pk play s3` | frame time p50 / p95 as in S2 (16.91 / 17.27); Pokopia's frame step stays at 60 | |
| 5 | S3a, Mario Kart World, no window changes | `s3a_run.sh mkw play s3` | as in S2 (16.67 / 17.36) | |
| 6 | S3a, Donkey Kong Bananza, no window changes | `s3a_run.sh dk play s3` | as in S2 (16.67 / 17.52) | |
| 7 | S3a, Donkey Kong Bananza, display asleep 110-130 s | `s3a_run.sh dk sleep s3` (the user at the Mac: the display sleeps and may lock) | probe fps at least 59.5 while asleep; `the displays went to sleep` / `woke` logged | |
| 8 | S3b, Pokopia, input from the probe only | `s3b_run.sh pk input s3` | DM_REC holds the probe's presses as the game read them; the recording (`stream/s3_pk_input.h264`) shows the walk of the route (the user watches it) | |
| 9 | S3b, Mario Kart World, input from the probe only | `s3b_run.sh mkw input s3` | as 8; the menus are passed and the race starts, later than with DM_KEYS by the connection time the log prints | |
| 10 | S3b, Donkey Kong Bananza, input from the probe only | `s3b_run.sh dk input s3` | as 8 | |
| 11 | S3b, Pokopia, pause and resume | `s3b_run.sh pk pause s3` | no frame 50-65 s and 80-90 s; `graphics suspended` / `resumed`, `oe focus state → 3` then `→ 1`; DETACH without pause at 90 s lets the game go on at the Mac; frames again after each resume | |
| 12 | S3b, Mario Kart World, pause and resume | `s3b_run.sh mkw pause s3` | as 11 | |
| 13 | S3b, Donkey Kong Bananza, pause and resume | `s3b_run.sh dk pause s3` | as 11 | |
| 14 | S3b, sound through a pause, with the user listening | `SOUND=1 s3b_run.sh pk pause s3` | the Mac stays silent while attached and while paused; the sound comes back after the DETACH without pause | |

## Hub and TV test list

The hub and the tvOS app pass their automatic tests (loopback, fakes and `stream_probe`). This round covers what only the home network, the Pro, the Apple TV and the real games can check, after the dmhost round above. **[user]** is the user's action, **[agent]** runs here, **[together]** is the user watching while the agent measures.

Rules of the round:

- Every game opening goes through `boot.lock`, one at a time. With a `STOP_*` file in `/Volumes/Hangar/Games/overnight/state`, nothing opens.
- `horizon-fakestream` uses the same hardware encoder as dmhost: nothing is built during a measured boot.
- Real games only with Donkey Kong Bananza and Mario Kart World, on the test profile with test saves. The agent does not open Pokopia, and the players' saves never enter a test.
- The agent does not sign or install anything: signing, installing HorizonHub (`scripts/install_hub.sh`) and installing HorizonTV from Xcode are the user's.

**1. The Mac app**

| # | Step | Expected | Result |
|---|---|---|---|
| 1.1 | [user] `scripts/install_hub.sh` (with `apps/Config/Signing.local.xcconfig` in place), then the SSD password item ([apps/README.md](apps/README.md#install-and-first-start)) | HorizonHub opens; its TV section reads "Hub: Waiting for the TV on the network" | |
| 1.2 | [user] Accept the Local Network prompt (or System Settings › Privacy & Security › Local Network) | HorizonHub is on in the list | |
| 1.3 | [user] With the macOS firewall on, allow incoming connections to HorizonHub | no block | |
| 1.4 | [user] Open the HorizonHub window with the SSD connected | the removable-volume prompt appears once and the catalog loads | |

**2. A recorded game instead of a real one**

`horizon-fakestream` stands in for dmhost: same `boot.lock`, same `DM_STREAM`, same peer check by the hub. It replays the S2 recordings (`dk_s2_play.h264`, `mkw_s2_play.h264`) in a loop.

| # | Step | Expected | Result |
|---|---|---|---|
| 2.1 | [agent] `swift build -c release --product horizon-fakestream` in `apps/`; write `~/Library/Application Support/HorizonHub/games/fake-catalog.json`: the real guard state, the test profile with saves in a test folder, games "DK recorded" and "MKW recorded" whose `host` is the fakestream and whose `program` is the recording | the file loads | |
| 2.2 | [agent] Reopen the app on it: `open --env HORIZON_GAMES_CATALOG=<file> ~/Applications/HorizonHub.app` | the window lists the two recorded games | |
| 2.3 | [user] Open "DK recorded" from the Mac | the TV section reads "Game video: The game is connected" | |

At the end, quit and open the app without `--env` to go back to the real catalog.

**3. The receiver on the Pro** (a Wi-Fi client, as the TV will be; the agent runs it over SSH)

| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | [agent] Copy `apps/` to `pro:scratch/horizon-bench/` (without `.build`), then `swift build -c release --product horizon-receiver` there | builds | |
| 3.2 | [user] HorizonHub › TV › Pair a TV…; [agent] `horizon-receiver --seconds 120` on the Pro (it finds the Mac over Bonjour; its identity and known Macs are in `~/Library/Application Support/HorizonReceiver/`) | the terminal shows the code to type on the Mac | |
| 3.3 | [user] Type the code on the Mac and confirm | the Pro appears among the paired TVs; the receiver gets video | |
| 3.4 | [agent] Three runs of `horizon-receiver --headless --seconds 300 --tsv ~/hr/wifi-N.tsv` | each final summary has present to decoded p95 under 25 ms; an undecoded frame counts as over | |
| 3.5 | [agent] `horizon-receiver --seconds 300 --tsv ~/hr/drop-1.tsv --drop media=0.01,feedback=0.01,burst=200x20,seed=7` | the longest run of undecoded frames is at most 3; repairs and refreshes show in the Mac's TV section | |
| 3.6 | [together] `horizon-receiver --window --seconds 300 --png ~/hr/png --png-every 10` (needs the Pro's graphical session); the PNGs come back to the Air | the right picture, no green blocks or tearing; continuous sound | |
| 3.7 | [user] Quit and reopen HorizonHub while the receiver runs | the receiver reconnects in a few seconds without pairing again | |
| 3.8 | [user] Forget the Pro in the Mac's list | the receiver drops and asks to pair | |

**4. The Apple TV with the recorded game**

| # | Step | Expected | Result |
|---|---|---|---|
| 4.1 | [agent] `xcodegen generate` in `apps/`; [user] open `Horizon.xcodeproj`, pick the HorizonTV scheme and the Apple TV (paired in Settings › Remotes and Devices › Remote App and Devices), run | HorizonTV opens on the TV | |
| 4.2 | [user] Accept the TV's local network prompt if it appears | the TV lists the Mac | |
| 4.3 | [user] On the Mac: Pair a TV…; on the TV: pick the Mac, then Continue | the TV shows 6 digits; typed on the Mac, the TV goes to the catalog | |
| 4.4 | [user] Quit and reopen the TV app | it goes straight to the paired Mac, with no new code | |
| 4.5 | [user] Pick the profile and "DK recorded" | 60 fps video and sound; on-screen statistics (in the menu) show fps and latency | |
| 4.6 | [user] Siri Remote: Menu during the game | the game menu opens without leaving the app; Menu again closes it | |
| 4.7 | [user] Controller: hold + and − for 1 s | the game menu opens; the controller's B does not leave the game | |
| 4.8 | [user] In the menu, change resolution, rate and codec | the video goes on after a moment; the statistics show the new size | |
| 4.9 | [user] Back to the Mac | the TV goes back to the catalog and the game goes on on the Mac; the running game's entry resumes it on the TV | |
| 4.10 | [user] The Siri Remote's TV button, wait 10 s, back to the app | the TV shows that it is coming back and the video returns by itself | |
| 4.11 | [user] Turn the Mac's Wi-Fi off for 20 s (TCP gives up after ~11 s with no answer) | the TV shows that it is reconnecting and returns to the game | |
| 4.12 | [user] 15 min without touching the controller | the screen saver does not start | |
| 4.13 | [user] Close the game and confirm | the game closes on the Mac and the TV goes back to the catalog | |

**5. Real games** (with the user's go and a window with no other boot; Donkey Kong Bananza and Mario Kart World, test profile, test saves)

| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | [user] Open Donkey Kong Bananza from the Mac | the game's log has `fs mount save` in the profile's folder and the profile's nick; the window comes to the front with focus | |
| 5.2 | [user] Close it from the Mac | the real dmhost ends and `boot.lock` is free | |
| 5.3 | [user] Mario Kart World for 30 min (played or idle) | no GPU hang; if one happens, everything stops and the analysis is offline | |
| 5.4 | [user] Donkey Kong Bananza from the TV with a controller | buttons by position (an Xbox controller's A is the Switch's B; "by letter" in the menu swaps them); sticks with a dead zone | |
| 5.5 | [user] Mario Kart World from the TV with two controllers | the game sees two players; turning one controller off removes its player | |
| 5.6 | [user] The TV button in the middle of a race, then back | the game pauses on the Mac (focus away, as the Switch's Home) and resumes on return | |
| 5.7 | [user] 30 playable minutes end to end from the TV (J4's acceptance) | no noticeable stall; the hub's TSV is in `~/Library/Application Support/HorizonHub/games/stream-logs` | |

Decisions for the user: the real profile names and nicks (`DM_NICK`) for the final catalog; Mario Kart World's 30 min played or idle; AWDL left alone unless Wi-Fi latency spikes of ~100 ms appear (then whether to turn AirDrop off during play); removing the test profile and saves after the checks.

Known limits: a client that loses its decoder references (tvOS invalidates the session, or the decoder restarts) cannot decode an LTR refresh, so the TV and the receiver ask for the video again (ATTACH) after 2 s without a keyframe; asking for a keyframe directly needs a protocol change in dmhost. The Switch's Home has no path from the TV yet: `PAD` v1 has no bit for it, so + and − for 1 s opens the TV app's menu (back to the Mac, close the game). Pokopia takes 50–80 ms from present to encode until S3a's pacing changes that.

## Design

### S1: capture and encode

- **Capture point:** the frame comes from the general present path, not from the present snapshot ring. Only the Pokopia and Breath of the Wild profiles turn `present_snap` on; Donkey Kong Bananza and Mario Kart World do not.
- **Copy into the encoder's texture:**
  - The frame is drawn with `present_encode_m4` / `present_offscreen_m4` (`dm/gfx/nvn/nvn_mtl.m:12366`, `:12397`). These crop, flip and convert as the display path does.
  - The target is a 1080p texture backed by an IOSurface, from a `CVMetalTextureCache`, kept in the residency set.
  - The copy is encoded before `nextDrawable` (`nvn_mtl.m:12498`), which can block.
- **Encoder settings:**
  - `VTCompressionSession` with `RealTime`, `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` and no frame reordering;
  - long-term references (`EnableLTR`, `AcknowledgedLTRTokens`, `ForceLTRRefresh`) so that a loss is repaired without a full keyframe;
  - H.264 first, the case Apple documents for low latency with LTR; HEVC if S1 measures it working;
  - 1080p60, 20–30 Mbit/s to start.
- **Switch:** `DM_STREAM_FILE=<path>` writes Annex B and logs the encode time per frame.
- **Frameworks:** VideoToolbox, CoreVideo and CoreMedia are already linked (`dm/host/Makefile`), so no new dependency.
- **Measuring:** an A/B run starts only when `ProcessInfo.thermalState` reads 0 (nominal). The Air has no fan: after a few back-to-back boots the state reads 1 (fair) and the CPU and GPU slow down. Pokopia then fell to 16 fps 50 s into a run, with and without the encoder, against 59.9 fps and GPU p50 13.9 ms on the same route at state 0. The host logs the state in its `power up to frame` lines.
- **Found in S1 (2026-11-03):**
  - The per-frame table splits the encoder's own time (`encode_ms`) from the time a frame waited for the previous one to leave the encoder (`wait_ms`). The encoder takes one frame at a time.
  - Pokopia presents some frames in pairs, 0.3 ms apart, after a GPU backlog: about 5% of the frames on its walking route (414 and 436 of 7,600). The second frame waits about 5 ms. Counted as encode time, that wait made the p95 read 11 ms where the encoder's own p95 is 6.5 ms. Donkey Kong Bananza and Mario Kart World do it for fewer than 10 frames a run. S3a's pacing decides whether the older frame of a pair is dropped, as the display link does when it merges frames.
  - Present to encoded is about 7 ms on Mario Kart World and Donkey Kong Bananza. On Pokopia it is about 21 ms p50 and 50 to 80 ms p95. Its present comes before the GPU has drawn the frame, so the capture pass waits for that frame's own GPU work (14 ms p50). The Mac display gets the frame no sooner.
  - Results, frame time p50 / p95 (GPU p50), base runs then encoder runs, in ms:

    | Game | Window | Base | With the encoder |
    |---|---|---|---|
    | Donkey Kong Bananza | 112-148 s | 16.68 / 17.7 (13.2), 16.67 / 17.6 (13.3) | 16.69 / 17.7 (13.4); its other encoder run reached that stretch of the route 20 s late (16.91 / 32.7) |
    | Mario Kart World | 80-148 s | 16.67 / 19.3 (14.2), 16.67 / 17.7 (14.1) | 16.66 / 17.5 (14.1), 16.65 / 18.2 (15.1) |
    | Pokopia | 75-112 s | 16.3 / 26.9 (12.5), 16.2 / 28.4 (12.3) | 16.1 / 28.6 (12.7), 16.1 / 30.3 (12.7) |

### S2: local socket

- **Who connects:** `DM_STREAM=<unix socket path>`. HangarVault creates the socket and starts dmhost with its path; dmhost connects to it, and connects again after the hub restarts. A dmhost without a hub just does not stream.
- **Framing:** typed, length-prefixed messages.
  - Out: video access units with the present's host time and their reference and LTR info; audio PCM blocks (48 kHz, s16, stereo) with their time.
  - In: controller states, LTR acknowledgements and refresh requests, pause and resume, bitrate.
- **Audio tap:** the host's PCM, taken in `dm/host/hle_audio.c` before the AudioUnit or the silent sink.
- **Probe:** a Mac tool under `dm/tools/` that plays HangarVault's end of the socket. It writes the stream to a file and prints the socket hop latency.
- **Backpressure:**
  - A Unix stream socket buffers 8 KB by default on the Air (`net.local.stream.sendspace` 8192), so a single keyframe already pushes back.
  - Raise `SO_SNDBUF`, and write from a thread of its own with a bounded queue.
  - When the queue is full, drop frames and ask for an LTR refresh.
  - Nothing blocks in the VideoToolbox callback or the present path.
- **Hub crash:** set `SO_NOSIGPIPE`. Nothing in `dm/` handles SIGPIPE today, so a write to a dead hub would kill the game. When the socket breaks, dmhost detaches (pausing the game if a client was attached) and connects again.
- **Version handshake:** the first message carries the protocol version and the host's build. The pinned hosts (`runs/hosts/*`) will drift from the hub.
- **Always on:** the hub always passes `DM_STREAM`, so that a game started at the Mac can move to the TV later. With no client attached, the encoder does not run.
- **Audio mix:** a game can have several outputs open at once (`hle_audio.c` keeps up to 8; Fire Emblem Engage runs Wwise and FMOD side by side). dmhost sums them into one stereo stream after the 6 → 2 downmix and the output's volume, so the TV gets one stream. While a client is attached the Mac plays nothing: the outputs run on the silent sink's real-time pacing, and the tap sends what it consumes.

- **Found in S2 (2026-11-03):**
  - Results of the 150 s boots with the probe as hub, muted, through the guard (`/Volumes/Hangar/Games/overnight/stream/s2_run.sh <pk|mkw|dk> <play|detach|crash|base>`, read with `s2_check.sh`; S1's A/B is `s1_ab.sh` there); frame time p50 / p95 (GPU p50) in ms, in S1's windows:

    | Game | Window | Without the stream | With the probe as hub | Hop p95 | Frames in the file |
    |---|---|---|---|---|---|
    | Pokopia | 75-112 s | 16.86 / 17.29 (13.78), same day and host | 16.91 / 17.27 (13.55); DETACH / ATTACH run 16.87 / 17.32 (13.71) | 0.045 ms (0.048) | 8,604 of 8,604 |
    | Mario Kart World | 80-148 s | S1: 16.67 / 19.3 (14.2), 16.67 / 17.7 (14.1) | 16.67 / 17.36 (14.72) | 0.053 ms | 8,336 of 8,336 |
    | Donkey Kong Bananza | 112-148 s | S1: 16.68 / 17.7 (13.2), 16.67 / 17.6 (13.3) | 16.67 / 17.52 (13.59); probe-dies run 16.68 / 17.39 (13.19) | 0.064 ms (0.063 after the reconnect) | 7,862 of 7,862 |

  - The encoder's own p95 stays 6.0-6.6 ms with the socket; no frame dropped from the socket queue or by the encoder on any run.
  - Pokopia's base run on 2026-11-03 evening is steadier than S1's base runs of the same day: p95 17.3 ms against 26.9 and 28.4, no dropped frame against 402 and 627, GPU p50 13.8 ms against 12.4. The cause is not known (open); S2 compares Pokopia with a base run made right after its stream runs.
  - With DETACH the Mac's sound comes back at once, and with ATTACH it goes to the stream again: the probe's `.wav` of the DETACH / ATTACH run is 77 s, the attached stretches. When the hub dies, dmhost logs the closed socket as a detach with pause, tries once a second (`ECONNREFUSED` while the dead hub's socket file stays), and the next hub gets HELLO and a key frame after its ATTACH.
  - The first `VTDecompressionSessionCreate` in a process blocks about 45 ms; later ones take 0.5-1 ms. The probe makes a warm-up session at start; the hub should do the same before its first ATTACH (told to HangarVault for J2).
  - The probe skips a script action that needs dmhost's HELLO when it fires before HELLO arrives, and any `attach` in a script turns its own attach off: a script starting with `0:attach` waits for the next `attach`. Start scripts at 1 s.
- **Open, from the S2 code review (2026-11-03):**
  - ~~An encoder session VideoToolbox invalidates is not recreated.~~ Fixed (2026-11-04, commit 63bf1c44): the encoder queue makes it again with the last size, codec and bitrate; `t_stream_sock` checks it.
  - ~~A hub that stops reading but keeps its socket open is never noticed.~~ Fixed (2026-11-04, commit 2b2e4942): a 5 s send deadline (`SO_SNDTIMEO`) closes the socket, which counts as a detach with pause while a client is attached; a hub stalled that long shows the TV nothing anyway.
  - ~~The hub is not told when ATTACH fails or when its size is replaced.~~ Fixed (2026-11-04, commits 64c81d27 and 1994f5d6): `ATTACH_RESULT`, type 7, agreed with HangarVault.

#### Protocol v1 (reviewed by HangarVault, 2026-11-03)

The hub and dmhost run on the same Mac. HangarVault reviewed the draft on 2026-11-03; its changes are in: reconnection, a client-chosen codec, controllers connecting and their style, a DETACH that hands the game back to the Mac without pausing, a size limit and skipping unknown types.

- **Socket:** `AF_UNIX`, `SOCK_STREAM`. The hub creates it (`~/Library/Application Support/HangarVault/games/stream.sock`, 74 bytes; at most 103, the `sun_path` limit, which the hub checks before it starts a game), listens and starts dmhost with `DM_STREAM=<path>`.
  - While it is not connected, dmhost tries to connect once a second. No socket (`ENOENT`) or no listener (`ECONNREFUSED`) is normal: HangarVault's J1 passes `DM_STREAM` before it listens. dmhost logs a plain line when the state changes, not a `[RED]` one.
  - After each connection dmhost sends `HELLO` again and starts detached. A hub that restarts recreates the socket at the same path (unlink, bind).
  - The hub identifies the dmhost on the other end with `LOCAL_PEERPID`, so `HELLO` carries no pid.
- **Clock:** every time is host nanoseconds from `mach_absolute_time` scaled by its timebase (`now_ns` in `dm/host/hle_os.c`). It is one clock for every process on the Mac, so the hub reads the socket hop as its own `now` minus `sent_ns`.
- **Byte order:** every integer is little-endian.
- **Header:** 16 bytes in front of every message. A payload is at most 8 MB: a larger length closes the socket with a `[RED]` line. A receiver skips a message of a type it does not know by its length, so later versions can add types.

  | Offset | Type | Field |
  |---|---|---|
  | 0 | u32 | payload length in bytes, not counting the header |
  | 4 | u16 | message type |
  | 6 | u16 | flags, by type; 0 when unused |
  | 8 | u64 | `sent_ns`, when the sender wrote the message |

- **dmhost to hub:**

  | Type | Name | Payload |
  |---|---|---|
  | 1 | `HELLO` | u32 protocol version (1); u64 title ID; u16 width, u16 height of the game's window; u32 audio rate (48000); u8 channels (2); u8 codec count; u8 pad[2]; that many u32 codecs the host can encode (`'avc1'`, `'hvc1'`); then the host's build as UTF-8 (git revision and build time) to the end of the payload. Sent first after each connection. |
  | 2 | `VIDEO_CONFIG` | the parameter sets (H.264 SPS, PPS; HEVC VPS, SPS, PPS), each as u16 length plus bytes. Sent before the first frame and before any frame whose parameter sets differ from the last ones sent. |
  | 3 | `VIDEO_FRAME` | u64 `present_ns` (the game's present); u64 frame number; i64 LTR token (-1 = none; return it in `LTR_ACK` once the frame decoded); then the access unit as AVCC, NAL units with 4-byte big-endian lengths, which `VTDecompressionSession` takes as it is. Flags: bit 0 sync frame, bit 1 LTR refresh frame. |
  | 4 | `AUDIO` | u64 host time of the block's first sample; u32 frame count; then that many frames of interleaved s16 stereo at 48 kHz. Blocks of 240 frames (5 ms). |
  | 5 | `STATS` | once a second: the encoder's last window (encode p50 and p95, frames dropped because the queue was full, bitrate) as UTF-8 `key=value` pairs, for the hub's overlay and logs. |
  | 6 | `RUMBLE` | reserved for the game's vibration; v1 hosts do not send it. |
  | 7 | `ATTACH_RESULT` | after every `ATTACH`, the one that resumes a paused game included, ahead of the new session's first frame: u8 ok (1 the encoder started; 0 it did not and no client is attached); u8 pad; u16 width, u16 height in use; u16 pad; u32 codec in use; then a reason in UTF-8 to the end of the payload, when ok is 0 or the size asked for was changed (out of 64 to 4096, or odd). Also sent with ok 0 when an encoder session VideoToolbox invalidated cannot be made again. Agreed with HangarVault on 2026-11-04; a hub that does not know it skips it, so the version stays 1. |

- **Hub to dmhost:**

  | Type | Name | Payload |
  |---|---|---|
  | 1 | `HELLO` | u32 protocol version the hub speaks. A dmhost that does not speak it closes the socket, logs a `[RED]` line and does not reconnect; the hub then reports the host as out of date. |
  | 16 | `ATTACH` | a client is watching: u16 its refresh rate (Hz); u16 width, u16 height it shows; u16 pad; u32 codec, one `HELLO` listed; u32 starting bitrate (kbit/s). dmhost starts the encoder at that size, sends a sync frame and starts the audio tap; the Mac plays no sound. After a `DETACH` that paused the game, `ATTACH` resumes it. |
  | 17 | `DETACH` | no client any more. dmhost stops the encoder and the tap and releases every controller the hub set. Flag bit 0: pause the game as the Switch's Home button does (the TV app went to the background, the network dropped; S3b). Without it the game goes back to the Mac as it is, with its sound. |
  | 18 | `PAD` | u8 player (0 = player 1); u8 pad[7]; u64 buttons (`dm/host/dm_input.h` bits); i16 lx, ly, rx, ry (±32767); flag bit 0: six-axis data follows, f32 acc[3] in G and f32 rot[3] in rad/s, in the Switch frame. A full state each time, sent on change and at least every 100 ms. A player `PADS` has not connected is ignored. |
  | 19 | `LTR_ACK` | u16 count, then that many i64 tokens of frames the client decoded. |
  | 20 | `REFRESH` | the client lost a frame: the next frame is encoded from an acknowledged LTR, or as a sync frame when none is. |
  | 21 | `BITRATE` | u32 kbit/s for the frames that follow. |
  | 22 | `PADS` | the controllers the client has: u32 mask (bit p: player p + 1 connected); u8 style[8], one per player (1 = Pro Controller). v1 hosts report every connected player as a Pro Controller, the Switch's full-key style, as they do for the Mac's own controllers. Sent after `ATTACH` and whenever a controller comes or goes. Local multiplayer (Mario Kart World) reads the player count from it. |

- **Queue:** dmhost writes from one thread, with `SO_SNDBUF` at 4 MB. Its queue holds at most 8 video frames and 200 ms of audio. A video frame that does not fit is dropped, and the next one is encoded as a refresh, so the client never decodes against a frame it did not get. Audio blocks that do not fit are dropped oldest first; a block's time shows the gap. The hub reads the socket on a thread of its own and keeps its own queue per client, so the local queue seldom fills.
- **End:** either side closes the socket (`SO_NOSIGPIPE`, so a write to a closed one returns `EPIPE`); dmhost also closes it when a write moves nothing for 5 s (`SO_SNDTIMEO`). dmhost releases the hub's controllers and goes back to connecting once a second. With a client attached, a closed or broken socket counts as a `DETACH` with pause: a hub that crashed while the TV played comes back in about a second, finds the game by its pid, and its `ATTACH` or `DETACH` decides. With no client attached the game goes on as it was.

### S3: input, pause, pacing

- **Focus arbitration:** today both the window (`front_mac.m:1296-1297`) and a TV detach (`dm_focus_set`, `hle_oe.c:86`) can set focus. While a client is attached, the TV's state wins; detached, the window's rules apply.
- **Activation:** a host started by another process is not activated. Behind another app's window its display link fires about once a second (`front_mac.m:1221-1223`). While streaming, pacing must not depend on it (S3a).

- **Input:** the states from the socket feed a network pad source in `dm/host/hle_hid.c`. It becomes player 1 while the TV is attached.
- **Pause:**
  - when the TV app is suspended (the TV's Home button), the hub detaches;
  - dmhost then sets focus out with `dm_focus_set` (`dm/host/hle_oe.c:86`), as the Switch's Home button does, and keeps the game alive until it attaches again.
- **Pacing:**
  - presents follow the Mac's `CAMetalDisplayLink` (`nvn_mtl.m:12686`), which stops when the Mac's display sleeps;
  - while a client is attached, presents are paced by a timer at the client's refresh rate instead;
  - minimizing the window suspends graphics today (`dm/host/front_mac.m:1298`). That must not happen while streaming.

#### S3a plan (approved by the user, 2026-11-03)

Found in the code (checked by an independent subagent):

- The display link paces presents (`DM_PRESENT_LINK=1`). When it goes silent (window covered: about one callback a second; display asleep: none), `mtl_present_wait` drops the queued frames after 100 ms. They never reach `present_now`, so never `stream_capture`. The rescue to mode 0 starts only at focus 1.
- Out of focus (2), in any focus handling mode, the host only notifies the game (modes 1 and 2) and answers `GetCurrentFocusState` with 2: any pause is the game's. Minimizing (focus 3) suspends audio and closes the graphics gate (`dm_gfx_suspend`), so the game's threads block at their next submit or present. Pokopia sets focus handling mode 1, Mario Kart World 2, Donkey Kong Bananza 3.
- The focus starts at 1 and becomes 2 only when the window resigns key.
- `present_now` captures before it takes a drawable and returns after the capture when there is no layer.

Steps:

0. Measure without changing anything: one 150 s boot per game with the probe as hub, the window covered 40-70 s, minimized 80-100 s and the display asleep 110-130 s (`DM_WINDOW_SCRIPT`, a test hook in `front_mac.m` that covers the window with one of its own and minimizes it through AppKit; `pmset displaysleepnow`, woken with `caffeinate -u`). Record the probe's fps per 5 s, the focus and the display link lines.
1. Focus (`hle_oe.c`): `dm_focus_set` keeps the window's state; while a client is attached the effective state is 1, and on DETACH the window's applies again. Computed under the focus lock (the window and the stream change it from different threads), keeping an open applet's 2 and the time focus came in. One function in `stream_mac.m` marks a client attached or not on every path (ATTACH, ATTACH again, a failed start, the socket closing, the file mode). Unit test in `t_oe.c`.
2. ~~Minimize (`front_mac.m`): while attached, minimizing suspends neither audio nor graphics.~~ Dropped with the user (2026-11-03): the game window cannot be minimized (step 0's results), so the window out of sight is the app hidden or the display asleep, which steps 1 and 3 cover. The `DidMiniaturize` handler still suspends audio and graphics; if the window ever gets a Minimize button, that handler has to skip the suspend while a client is attached.
3. Pacing (`nvn_mtl.m`): while attached, a flag of the stream's own keeps the display link out and the host's 60 Hz clock paces the game (the path without a link). While the window is not shown (covered, minimized, display asleep: an atomic the present thread reads), `present_now` returns after the capture without a drawable. On DETACH the link comes back. The link stays out even with the window visible, so the TV has one pacing source; switching on every occlusion change is the fallback if the frame time suffers.
4. Checks: unit tests, lint, an independent review before the first boot; per game one boot with step 0's sequence and one without it. Done when the probe's fps is at least 59.5 in every 5 s window, covered, hidden and asleep included; no focus change reaches the game while attached; frame time as in S2; DETACH brings back the display link and the window's focus.


Step 0 results (2026-11-03; `/Volumes/Hangar/Games/overnight/stream/s3a_run.sh <game> seq|sleep s3a0`, the host without S3a's changes; the probe's fps per 5 s):

| Game | Window covered | App hidden (focus 2) | Display asleep | Otherwise |
|---|---|---|---|---|
| Pokopia | 32-56 | 0-12 | not run | 60 |
| Mario Kart World | 46-59 (the rescue takes over after each 500 ms of silence) | 0-21 | not run | 60 |
| Donkey Kong Bananza | 39-48 (60 in S2 at that point of the route) | 0-12 | 1.6-18 (focus 2 after the hidden stretch) | 60, but for the route's own loads at 30-45, as in S2 |

- The cover, a borderless window of the host's own, makes the game window's occlusion flap between visible and covered a few times; the display link goes silent and the rescue (mode 0) takes over only at focus 1. In mode 0 with the window covered, `nextDrawable` did not stall (Mario Kart World, 46-59 fps).
- Hiding the app takes the window's key status: the focus goes to 2 and stays there after `unhide` (the window is not key again), so no rescue comes and the stream starves. The display asleep does the same.
- The game window cannot be minimized today: it lacks `NSWindowStyleMaskMiniaturizable`, has no Minimize menu item, and `miniaturize:` leaves it as it is (the stream stayed at 60 fps through `mini`). The `DidMiniaturize` handler never runs on the Mac.
- This Mac locks its screen at display sleep (`sysadminctl -screenLock status`: immediate); after `caffeinate -u` the session was not locked and the window came back visible.

Done in the code (2026-11-03):

- Step 1: `focus_sync` in `hle_oe.c` computes what the game sees from the window's state, an open applet and `dm_focus_stream`; `st_client` in `stream_mac.m` marks the client on ATTACH, a failed ATTACH, DETACH and the socket closing. `t_oe` 63 checks.
- Step 3: `mtl_stream_pace` keeps the display link out while attached (`link_sync` wants mode 0); `present_now` returns after the capture without a drawable when `front_window_shown()` is 0 (`front_mac.m`: occlusion and `NSWorkspaceScreensDidSleep` / `DidWake`). When pacing ends, the link's last tick and stall start are reset, so the rescue does not fire on a link that was out on purpose. `t_stream_sock` 55 checks.
- `DM_WINDOW_SCRIPT` keeps `cover` / `uncover` / `hide` / `unhide`.
- From the independent review: the file mode (`DM_STREAM_FILE` without `DM_STREAM`) does not mark a client, on purpose: it checks the encoder with the window as it is. `g_window_visible` starts at 1 and takes the first occlusion notification, which AppKit sent at the window's opening on every step 0 boot.

Risks to check: without the link, the frame step judges lateness by cost, which once stepped Breath of the Wild to 30 by mistake (`hle_nvn.c` near the snapshot check): Pokopia could step down while attached. A drawable taken just as the display sleeps can wait up to 1 s. Either one is brought to the user before the plan changes.

Out of S3a: the pause on DETACH and the network controller (S3b), TVs at 50 Hz.

#### S3b plan (2026-11-03)

Found in the code:

- `stream_mac.m` reads PAD and PADS and only counts them; DETACH with pause logs that the game would pause.
- `hle_hid.c` merges per player: player 1 is the keyboard, `DM_KEYS`, its controller and the players merged into it (OR of buttons, the stick deflected more); players 2-8 each have the front end's controller path (`dm_pad_set_player`), connected while `dm_pad_players` has their bit. Six-axis: GameController, then the passive HID source (already in the Switch frame), per player.
- The host's suspend, as on iOS and in `DM_OE_SCRIPT`'s `bg=1`, is focus 3, `dm_audio_suspend`, `guest_clock_freeze_for(1)` and `dm_gfx_suspend` (the gate the game's submits and presents wait at), undone in the reverse order. `dm_gfx_suspend(1)` waits for in-flight submits and presents, so it cannot run on the encoder queue that a present may wait for.
- `dm_audio_stream(NULL)` while audio is suspended puts the outputs on the silent sink, and `dm_audio_suspend(0)` restarts only outputs on the silent sink: suspending before the tap goes, and attaching the tap before resuming, keeps the Mac silent through a pause.

Steps:

1. Network controllers (`hle_hid.c`): a source of their own per player (`dm_net_pad_set`, `dm_net_pads`), merged as the Mac's controllers are; the connected players are the front end's and the hub's together, each source releasing its own players when they go. Six-axis from PAD goes to a source of its own in the Switch frame, ahead of the Mac's while fresh. Unit test in `t_hid.c`.
2. PAD and PADS (`stream_mac.m`): PADS sets the hub's players; PAD sets a connected player's state (buttons masked to the NpadButton bits and the shake bit, sticks clamped to +-32767, six-axis when the flag says); a player with no PAD for 1 s is released (the hub sends one at least every 100 ms); DETACH and a closed socket release every hub controller. `t_stream_sock` checks it.
3. Pause (`stream_mac.m`, `hle_oe.c`): DETACH with pause, or the socket closing with a client attached, suspends the game as the host's background does, and the game sees focus 3 (`dm_focus_stream(2)`). ATTACH resumes it at focus 1; DETACH without pause resumes it on the Mac with the window's focus. The suspend runs on the socket's threads outside the encoder queue. The Mac window's own focus changes wait while paused; nothing on the Mac resumes a paused game (open: the user decides whether clicking the window should).
4. Probe (`dm/tools/stream_probe`): `--keys` with `DM_KEYS`' syntax in seconds (names, `~hold`, `*count/interval`), sent as PAD on change and every 100 ms while attached; `pads=MASK` in `--script`.
5. Checks: unit tests, lint, an independent review; the boots are in "Test list".

Done in the code (2026-11-04):

- `t_hid` 158 checks (11 for the network source), `t_oe` 68, `t_stream_sock` 77, `t_stream` 378; TSan on `t_hid`; no new lint finding.
- From the independent review: the host's clock keeps pacing presents while paused (the drain otherwise waited on the display link or a drawable of a display that may be asleep), and the display link comes back only when the game goes on at the Mac; the 1 s PAD release runs on a timer of its own (it ran only when a frame was encoded); PAD and the release take one lock, so a release cannot wipe a PAD that came in between; a hub refused for its protocol version lets a paused game go on at the Mac; DM_REC records the hub's shake too.
- `DM_HID_RECEIPT_LOG`, described in `dm_input.h`, has no implementation; the input checks use `DM_REC`, which writes what the game's own reads of player 1 saw.

Open, from the S3b review:

- `DM_OE_SCRIPT`'s `bg=0` during a stream pause resumes the game and the Mac's sound while the hub believes it paused, and an ATTACH during `bg=1` undoes the script's suspend: both use `dm_app_suspend` without counting who holds it. Only test scripts reach it.
- An ATTACH that fails while paused (no encoder, no IOSurface) leaves the game paused; the hub now gets `ATTACH_RESULT` with ok 0, and a DETACH without pause gets the game back.
- Nothing on the Mac resumes a paused game; whether clicking the window should is the user's call.
