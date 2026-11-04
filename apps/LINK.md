# HorizonHub ↔ HorizonTV link (version 1)

How the game leaves the Mac and reaches the Apple TV. The game side (dmhost ↔ hub, local socket) is in [STREAMING.md](../STREAMING.md), "Protocol v1", and [dm/host/stream_proto.h](../dm/host/stream_proto.h). This document covers hub ↔ client.

## Parts

| Role | Where | What |
|---|---|---|
| Game socket | [`Sources/HubKit/StreamSocket.swift`](Sources/HubKit/StreamSocket.swift) | Listens on `GamesSettings.streamSocket` (≤ 103 bytes, 0600); accepts only the process of the open session (`ProcessIdentity`: pid and start time); a new connection replaces the old one |
| Server | [`Sources/HubKit/LinkServer.swift`](Sources/HubKit/LinkServer.swift) | TCP `NWListener` with Bonjour; one UDP socket for all clients; one `PacedSender` per client |
| Bridge | [`Sources/HubKit/StreamBridge.swift`](Sources/HubKit/StreamBridge.swift) | dmhost ↔ connected client; per-frame TSV; feedback watchdog |
| Pairings | [`Sources/HubKit/PairingStore.swift`](Sources/HubKit/PairingStore.swift) | Hub identity in the Keychain (`dev.joaoalvess.horizon.hub` / `link-identity`, base64 of the X25519 private key); clients in `clients.json` (0600) |
| App | `HorizonHub/TVHub.swift`, `HorizonHub/TVSection.swift` | The "TV" section of HorizonHub: pair, enter the code, forget, stream numbers |
| Client | [`Sources/HorizonLink/LinkClient.swift`](Sources/HorizonLink/LinkClient.swift) | Control, UDP, video reception, feedback, NACK, clock, `LinkDrop` |
| Shared core | [`Sources/HorizonLink/`](Sources/HorizonLink/) | `LinkSession` (hello, pairing, Noise), `Noise`, `DatagramCipher`, `ReplayWindow`, `ReedSolomon`, `VideoShards`, `MediaPlane` (`VideoSender`, `VideoReceiver`), `MediaSocket` (`MediaSocket`, `PacedSender`), `ClockSync`, `Controller` (`PadMapper`, `PadSchedule`, `MenuCombo`), `DMStream` |
| Fake source | [`Sources/horizon-fakestream/`](Sources/horizon-fakestream/) | Re-encodes a Switch 2 `.h264` recording and speaks v1 like dmhost (`DM_STREAM=<sock> horizon-fakestream <recording>`) |

## Discovery

Bonjour `_horizonhub._tcp`, with the Mac's name. The TXT record carries `v=1` and `id=<hubId in hex>`. The `hubId` is the first 8 bytes of the SHA-256 of the hub's public key.

## Control (TCP)

- **Frames:** a u32 LE length, followed by the body; at most 65535 bytes, the Noise message limit.
- **Clear phase** (`ClearMessage`). The first byte is the type:

  | Type | Message | Body |
  |---|---|---|
  | 1 | clientHello | u16 version, client key (32), name in UTF-8 |
  | 2 | hubHello | u16 version, hubId (8), u8 paired, name |
  | 3 | pairCommit | SHA256("horizon pair commit" ‖ Pc ‖ Nc) |
  | 4 | pairHubKey | Ph (32), Nh (32) |
  | 5 | pairReveal | Pc (32), Nc (32) |
  | 6 | pairResult | u8 accepted, reason |
  | 7 | handshake | Noise message |
  | 8 | refused | reason (shown on the TV) |

- **Pairing** (numeric comparison with commitment):
  - **Sequence:** the client commits, the hub answers with Ph and Nh, and the client reveals.
  - **Code:** the first 8 bytes of SHA256("horizon pair sas" ‖ Pc ‖ Ph ‖ Nc ‖ Nh), modulo 10⁶, as 6 digits. The TV shows the code and the person types it on the Mac.
  - **`PairingGate` rules:** the pairing window ("Pair a TV…") lasts 2 min. Each commitment counts as an attempt, with at most 3 per window. Only one ceremony runs at a time, abandoned after 90 s. An accepted pairing closes the window.
  - **Revealed key:** must be the same as in the clientHello.
  - **Hub id:** the client checks that the `hubId` matches Ph.
- **Session:** `Noise_KK_25519_ChaChaPoly_SHA256`.
  - The prologue is "horizon link v1" ‖ clientHello ‖ hubHello, as they were sent.
  - The client initiates and the hub accepts only paired keys.
  - The payload of the first message is empty: an attacker can replay it, and it has no side effect.
  - From then on, each frame is an encrypted `ControlMessage`.
- **`ControlMessage`:**
  - hub → client: welcome (UDP port, sessionId, hub name), catalog (profiles, and games with their status), state (game, profile, streaming, paused), notice;
  - client → hub: attach (`DMStream.Attach`; kbps 0 = the hub's default, 25000), detach(pause), open(profile, game), close, pads, bitrate;
  - both directions: stats, keepalive (every 2 s).
- **TCP:** keepalive at 5 s / 2 s / 3; noDelay; interactive video `serviceClass`.

## Media (UDP)

- **Datagram:**
  - a 12-byte header, used as AAD: u8 version 1, u8 channel, u16 0, u64 LE counter;
  - then ChaCha20-Poly1305, with the nonce taken from the counter, and the 16-byte tag;
  - 28 bytes of overhead; a 1200-byte budget, so up to 1172 bytes of payload.
- **Keys:** HKDF-SHA256 of each direction's Noise transport key, with salt = the handshake hash and info "horizon datagram".
- **Anti-replay:** a window of 4096 counters (RFC 6479). The counter is checked, authenticated, and only then recorded.
- **Addresses:** the hub learns the client's address from the first authenticated datagram (a hello with the welcome's `sessionId`) and follows changes only in authenticated datagrams. The client sends to the control connection's IP, on the welcome's port.
- **Sending** (`PacedSender`):
  - sealing on the send thread, in counter order;
  - the priority queue first, then micro-bursts of 24 video datagrams with 250 µs between them;
  - `SO_NET_SERVICE_TYPE` = VI; 4 MB buffers.

| Channel | Direction | Body | Cadence |
|---|---|---|---|
| 1 hello | client → hub | u32 sessionId | at start and every 1 s |
| 2 video | hub → client | shard (below) | per frame; repairs in the priority queue |
| 3 audio | hub → client | u64 host time, u32 sequence, 240 frames of s16 stereo 48 kHz (960 B) | every 5 ms, priority |
| 4 feedback | client → hub | u32 last complete, u32 last decoded, u32 refresh request, u32 shards received, u32 recovered, u32 frames lost, u32 decode p95 (µs), u8 n, n × i64 LTR | every 20 ms, and at once on a refresh request |
| 5 nack | client → hub | u32 frame, u8 n, n × (u8 block, u8 missing); n = 0 asks for the whole frame | per incomplete frame |
| 6 ping | client → hub | u32 sequence, u64 client send time | every 250 ms |
| 7 pong | hub → client | u32 sequence, u64 client send time, u64 hub arrival, u64 hub departure | reply |
| 8 decoded | client → hub | u32 frame, u64 decode time | per decoded frame |
| 9 pad | client → hub | u32 sequence, u16 flags, v1 PAD payload | on change and every 50 ms |

### Video

- **Envelope** (`FrameEnvelope`): u64 present (hub clock, dmhost's `now_ns`), u64 dmhost frame number, i64 LTR, u8 n and n × (u16 length + parameter set), then the access unit.
- **Parameter sets:** sent in every sync or refresh frame, in the first frame after a new VIDEO_CONFIG, and after each refresh request.
- **Shard:** a 16-byte header:
  - u32 link frame (continuous; it does not go back to 1 while the bridge lives);
  - u8 block, u8 blocks, u8 index, u8 data, u8 parity, u8 flags (1 sync, 2 refresh, 4 configuration);
  - u16 configuration generation, u32 frame bytes;
  - then 1156 bytes of shard.
- **Blocks:** each has up to 48 data shards. Reed-Solomon GF(2⁸) with a Cauchy matrix (polynomial 0x11D); parity row 0 is the XOR. Initial parity of 10%, at least 1 per block. Data shards are interleaved across blocks, and parity goes after them.
- **Repair:** the hub keeps the last 6 frames and answers a NACK with new parity, what is missing + 1. Each NACK brings parity rows not sent before.
- **Client** (`VideoReceiver`):
  - delivers in order;
  - an immediate NACK when a newer frame arrives while an earlier one is incomplete; a timer NACK 3 ms after the last shard; up to 3 NACKs, 8 ms apart;
  - gives up on the front frame 30 ms after its first shard;
  - on giving up, raises the refresh request (at most 1 every 100 ms while one is open) and drops frames until a sync or refresh frame with the configuration of its generation arrives;
  - a lost sync or refresh frame allows a new request at once.

## Hub ↔ dmhost

| From the client or the network | To dmhost |
|---|---|
| attach | ATTACH (kbps 0 becomes 25000; a codec not in HELLO becomes the first one in HELLO); repeated when dmhost reconnects and sends HELLO |
| detach(pause) | DETACH with or without pause |
| feedback with new LTR tokens | LTR_ACK with only the new ones (the hub remembers the last 256) |
| feedback with a higher refresh request | REFRESH, and the configuration sent again |
| nack | nothing: extra parity from the stored frame |
| pads / pad | PADS / PAD (a PAD with an older sequence is dropped) |
| bitrate | BITRATE |
| 1 s without feedback | DETACH with pause; state goes out as paused. Feedback coming back sends ATTACH again |
| client disconnected | DETACH with pause |

- An ATTACH_RESULT with ok = 0 becomes a notice on the TV: "The game did not start the video: …". When the size was changed, the notice is "The game adjusted the video: …".
- Video and audio flow only while a client is connected and not stalled.

## Clock and measurements

- **Client clock:** `ClockSync` uses the lowest-RTT sample of the last 10 s. Offset = hub − client.
- **Clock-free bound:** the `decoded` echo gives the hub a present → decoded bound that does not depend on the clock: echo arrival − present.
- **Hub TSV:** `~/Library/Application Support/HorizonHub/games/stream-logs/stream-<date>.tsv`.
  - `frame` lines: link frame, dmhost frame, flags, bytes, data and parity datagrams, present, dmhost `sent_ns`, hub arrival, queue.
  - `decoded` lines: the bound in ms.
  - Events: attach, attach-result, config, nack, refresh, stall, resume, detach, bitrate, client-address, host-disconnected.

## Controllers (J4)

- **Mapping** (`PadMapper`):
  - positional by default: the bottom face button of the Apple TV's controller becomes the Switch's B, the right one A, the left one Y and the top one X; `.labeled` follows the names;
  - L1/R1 → L/R; L2/R2 → ZL/ZR from 0.3; menu → +; options → −; stick clicks;
  - sticks with a radial dead zone of 0.08, scaled up to ±32767.
- **Sending:** `PadSchedule` sends on change and every 50 ms (dmhost releases a player that has sent no PAD for 1 s).
- **App menu:** `MenuCombo`: holding + and − together for 1 s opens the app menu. While both are held, the game receives neither.
- **Home:** v1 has no Home bit; the Switch's pause comes from DETACH with pause.

## Tests

- `swift test --filter HorizonLinkTests`:
  - the Noise KK vector, the datagram cipher and the anti-replay window, RS and shards (with a benchmark in release);
  - pairing, messages, the media plane with random loss, a whole lost frame, a burst, a configuration change and joining midway;
  - the UDP socket and paced sending, controllers.
- `swift test --filter HubKitTests`:
  - `StreamSocketTests` and `BridgeTests`, end to end over loopback: pairing, in-order video, LTR, repaired loss, REFRESH, lost feedback, a restarted hub.
