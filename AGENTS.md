# Agent Guide — MeshCoreRepeaterManager

## Project

Standalone Android-first Flutter/Dart app that pushes firmware updates to
MeshCore repeaters over LoRa through a stock companion device. The app talks
to the companion over BLE or TCP and uses it purely as a radio; the encrypted
OTA ops ride the same REQ/RESPONSE path as an admin `ota status` request. The
app/product name is **MeshCoreRepeaterManager**. iOS is deferred until there is hardware
to test on; Windows, macOS and Linux desktop builds use the same TCP path.

This is a personal project under `jhuebert/MeshCoreRepeaterManager`. The repeater side of
the feature lives in the `lora-ota` branch of `jhuebert/MeshCore`
(`examples/simple_repeater/OtaUpdate.*`), and the two halves must stay in
sync. The reference repos in the workspace (`MeshCore/`, `MeshChameleon/`,
`openhop_core/`) are read-only: do not edit them as part of this project.
`mesh_protocol`, `device_link` and `test_support` are reused from
MeshChameleon via `git subtree`; prefer fixing bugs upstream there (via
subtree) over diverging, retain MIT attribution, and keep `ATTRIBUTION.md`
accurate.

## Before starting work

1. Read `README.md` (the user guide) and this file. `SECURITY.md` has the
   threat model, `CHANGELOG.md` every user-visible change, and
   `docs/releasing.md` the release procedure.
2. Check `git status` before editing and leave unrelated work alone.
3. Inspect the relevant package code and the fork's `OtaUpdate.h` before
   changing anything that touches the wire contract.
4. The offline library and settings are persisted user data. A layout change
   must migrate the previous format and be tested with old-format fixtures;
   never silently discard images or the offline flag.

## Repository layout

- `app/` — Flutter UI, screens, orchestration, theme, app icon and desktop
  runners (Android, Linux, Windows, macOS).
- `app/test/` — widget and pure-Dart app tests. `support.dart` has the shared
  fixtures (`FakeLibrary`, `Catalog`, `OtaStatus`/`OtaNodeInfo`); use it for
  every screen test instead of touching platform plugins.
- `packages/ota_core/` — the wire contract (op frames, CRC), the frozen `ota
  status` CLI-line parser, `OP_INFO` parsing, the delta engine (rolling-hash
  matcher), and the windowed transfer engine (REQ/RESPONSE, op retry from
  `next_expected`).
- `packages/mesh_protocol/` — pure-Dart protocol constants, codecs, identity,
  crypto, packet models/builders (MeshChameleon subtree).
- `packages/device_link/` — pure-Dart `RadioLink` SPI, TCP/BLE/fake transports,
  binary requests (MeshChameleon subtree).
- `packages/companion_client/` — contacts, login, `remoteCli`, message pump.
- `packages/test_support/` — dev-only framed TCP client and test plumbing
  (MeshChameleon subtree).
- `bench/` — hardware harness (never run in CI):
  `--scenario probe|measure|full|delta|reject|cancel|rollback`.
- `scripts/check.sh` — the full analysis and test gate; `scripts/coverage.sh`
  adds the coverage gate; `scripts/build.sh` injects build metadata.
- `.github/workflows/ci.yml` — the gate plus platform builds;
  `release.yml` — the manual signed release.

Keep protocol/core packages free of Flutter or platform imports. Platform code
belongs in `app/`.

## Current state and next milestone

The full flow is implemented and hardware-exercised: connect, pick a repeater,
admin/ACL login, `OP_INFO` handshake, board-scoped version picker, delta or
full-image staging, windowed transfer, `ota apply`, post-reboot verification
and `ota rollback`. The app also carries a version-based offline library, a
three-way radio plan (live mesh / temporary private preset / the repeater's
radio2). The diff is computed by the repeater hashing its own running image;
no previous image is needed on the device. Release version strings are labels
for the offline library only, never diff inputs. `FirmwareLibrary.findBaseForSha`
and `findBaseFor` are legacy helpers with no production caller; do not
reintroduce a base picker or base matching.

Current fork release naming (no `filter`): tags and firmware stamps
`v<version>`, titles `Firmware <version>`, app-slot assets
`<env>-v<version>.bin`. Old `filter-v*` tags and `-filter-<sha>` names are not
accepted; a one-time startup pass drops saved library entries that still carry
them.

Planned and explicitly deferred:

- iOS (needs hardware).
- Refusing a release older than the OTA feature (there are currently no such
  releases in the field, so the check has nothing to test against yet).
- macOS/Windows code signing and notarization (the builds are unsigned; users
  bypass Gatekeeper/SmartScreen explicitly).

Do not claim hardware validation unless it was run against real hardware.
Transfer robustness, radio restore and the boot rollback have been exercised
on the bench; long multi-hop transfers in the field remain empirical.

## Stock-firmware parity

- The companion is **stock**. Do not require a custom companion firmware or a
  new payload type. The app uses `CMD_SEND_BINARY_REQ` (the same path as a
  status request), `CMD_SEND_LOGIN`, `CMD_SEND_TXT_MSG` and
  `CMD_RUN_CLI_COMMAND` as shipped.
- Match `MeshCore/docs/companion_protocol.md` and the pinned stock firmware
  (`MeshCore/examples/companion_radio/`) for frame layouts, command lengths,
  response codes and limits.
- Firmware parity for the target node is the fork's `OtaUpdate.h`: the app is
  a client of that contract, not a second implementation of it.

### Known intentional differences

- A blank admin password is sent as a valid login. Stock firmware treats a
  blank password as "is this key already in my ACL?"; the app exposes that
  instead of refusing empty input.
- The app re-reads and re-sends `tempradio` on the companion to restore it
  early rather than waiting out the timer. The command is the stock CLI.
- The picker scopes to the node's reported board, even though a user may
  deliberately choose another board (the node refuses a mismatch at staging).
- The offline library stores whole versions (all boards), not a per-device
  selection; that is the product decision, not a protocol constraint.

## The OTA wire contract — stability rules

`packages/ota_core/lib/src/wire.dart` mirrors
`examples/simple_repeater/OtaUpdate.h`; `OtaUpdate.h` is the authoritative
spec.

- The op stream rides inside ordinary admin REQ/RESPONSE datagrams:
  `[tag(4)][REQ_TYPE_OTA (1)][frame_len(1)][OTA frame]`. The crypto layer
  zero-pads the plaintext to a 16-byte block, hence `frame_len` — the node
  slices exactly that many bytes and ignores the padding. Nothing else about
  the frame is negotiated: magic `O`,`T`, CRC-16/CCITT-FALSE, frozen CRC and
  op order.
- `OP_INFO` (0x07) is the capability handshake — answered in every state.
  `OP_INFO_REPORT` (0x08) carries wire version, target id, slot size,
  `max_literal`, the feature bits (`supportsDelta`, `supportsApply`), the
  running firmware version (NUL-padded 32 bytes) and the **running image's
  SHA-256** — taken over exactly the bytes an update wrote (image length from
  the ESP image header, appended digest included), so it equals the hash of
  the app's own `.bin`. It is still used for post-reboot verification, but the
  app no longer needs a local image matching it: `OP_BLOCK_HASH` (0x09/0x0A,
  feature bit `0x00000004`) hashes ranges of the running image, and
  `OP_BLOCK_FIND` (0x0B/0x0C) locates up to twelve 64-bit rolling fingerprints
  in one scan of a window of it. Matches are found by content, not offset.
  `OP_LITERAL_Z` (0x0D) carries a chunked raw-DEFLATE stream of new bytes;
  the node inflates it with ESP32 ROM miniz into the staged slot. The app
  compresses at level 9 with `dart:io`'s GZipCodec minus its wrapper.
  All zeros means "cannot tell" (no readable image).
- `target id` is the **build environment** id (`sha256(pio_env)[0..3]`), not a
  hardware id. The app maps it back to an environment by hashing the names it
  knows from the catalog and library. Flashing a node with another variant of
  the same board (e.g. `_observer` ↔ plain) is refused by the node and by
  `stage()` — switch variants over USB/Wi-Fi, not OTA.
- `max_literal` counts the REQ envelope: `REQ_TYPE_OTA` + `frame_len` + the op
  frame overhead + the literal's length word all come out of one
  `MAX_PACKET_PAYLOAD` datagram (173 bytes with the current 184-byte payload).
- `PUSH_CODE_BINARY_RESPONSE` (0x8C) payloads arrive zero-padded to a 16-byte
  block; `unpadFrame()` trims them by CRC, so a report whose CRC ends in `0x00`
  still parses. Two record layouts exist (tag first, or pubkey prefix then
  tag); both are accepted, and the tag-at-2 candidate must frame before it is
  believed.
- New ops get new codes; existing ops never change meaning, field order or
  size; the SEQ rules and CRC are frozen. Hard breaks are a new REQ code,
  never a silent redefinition.
- `REQ_TYPE_OTA` is `0xA0`, a fork-private REQ code above upstream's
  `0x01..0x09` range (`0x08` is upstream's `subscribe`). Keep the app's
  `reqTypeOta` in sync with the repeater's constant; changing one alone breaks
  every update session.
- Unknown ops are dropped silently; a stray unknown op **inside a staged
  stream aborts staging** — that is deliberate.
- Don't reintroduce transport bindings ("wire v2") in docs/comments: nodes in
  the field predate any release, so this transport IS the format. Refer to it
  as the OTA wire contract.

## App UX contract

The UI/UX must be **maximally consistent across the whole app**. Use the same
glyphs, button labels, phrasing, spacing and formatting for the same idea on
every screen; shared building blocks live in `app/lib/widgets/common.dart`.
Design for the principle of least surprise: an operator who has never read the
docs should be able to predict what each control does and what happens next.
Follow familiar platform conventions, favor ease of use, easy visual scanning
and visual appeal over cleverness, and keep the text plain and user-centric.
**Do not use em dashes in any UI text or user-facing string.** Use a short
sentence, a colon or a comma instead. Primary action buttons are short names
with a single monochrome Material icon in front (next, play, pause, stop,
back), never a long label with an explanation appended. Shared `IconData`
constants live in `app/lib/widgets/common.dart`; do not use colored emoji as
button icons.

The app is an eight-step wizard: Connect → Repeater → Sign in → Firmware →
Radio → Review → Transfer → Verify. Every screen carries `WizardBar`
(step + label); the next action lives in a `WizardFooter` or an equivalent
bottom bar. Keep the flow linear — an action that belongs on the next
screen does not belong below the fold on the current one. One screen, one
main action: secondary buttons are text/outlined, and rarely more than one
is a filled button. The UI is aimed at operators with no MeshCore or
protocol knowledge — keep copy user-centric and jargon only where it is
accounted for (e.g. `radio2`, `tempradio` on the node CLI itself).

- **Connect**: BLE is Android/iOS only; TCP is a first-class path on every
  platform (Wi-Fi/Ethernet companion, serial-to-TCP bridge, local simulator).
  The firmware library is reachable here before any connection. Connecting
  lands the operator on the repeater step by itself — there is no
  "next" tap after connect; the connected card shows a single forward
  action (Continue) for the back-navigation case only.
- **Repeater**: repeaters and the manual public key are separate tabs. Long
  contact lists must never hide the key field or the admin login.
- **Sign in**: the password is optional (see parity above), and the bottom
  button signs in — always tappable; do not gate it on a non-empty
  password. There is no separate check/verify button: the bottom action is
  the check, and a successful one lands the operator on the firmware step
  by itself — no second tap; the step bar stays the way back. When signed
  in, the password card is hidden and the screen shows the node facts only.
- **Firmware**: versions are the unit. The GitHub tab shows one row per
  version — no board dropdown, no per-device rows; the app detects the
  node's board and downloads that board's image just-in-time when a version
  is tapped. Releases with no image for the detected board are hidden. The
  save button downloads **all** assets of a release (every board); the cloud
  icon shows the version's save state (not saved / partial / saved) and a
  trash icon deletes the whole version (any selected image is repaired).
  There is no Offline tab: offline mode shows only
  saved versions in the GitHub tab. Imported `.bin` files live on the
  Imported tab — one row per file — and are selected as the image to install;
  they are never used as a local delta base. The **Firmware library** on
  the main screen is this same screen in manager mode
  (`FirmwareScreen(updateMode: false)`): tapping a version downloads the
  whole version instead of selecting an update. The offline switch is
  persisted and must prevent every GitHub request (catalog included).
- **Radio**: three radio plans (live mesh with the path override, a temporary
  private preset on the repeater, or the repeater's radio2). Off-mesh modes
  are implicit zero-hop. The radio screen shows both current radio settings,
  including radio2's preset when enabled, and there is no duration input:
  the repeater's temporary window is renewed in fixed chunks. Show the plan's
  validation before the Next action, and never continue with an invalid one.
  Tempradio warns that an enabled radio2 is paused for the transfer.
- **Review**: a summary of everything selected before the update — companion
  and how it is connected, repeater name and board, current firmware, the
  firmware to install, image size, and the radio choice. No transfer time is
  guessed before the comparison; the exact comparison starts on Transfer after
  Start, and the live rate-based ETA appears there once ops land.
  Show the plan's validation before Start, and never start with an invalid one.
- **Transfer/Verify**: the first phase on Transfer is the comparison: it is
  armed **after** the chosen radio plan, so its many REQ/RESPONSE queries never
  go over the live mesh when an off-mesh channel was selected. Show progress,
  allow a stop that restores the radios, and stop before staging on an
  identical image. No screen may claim success until the node answers
  with the newly sent image's hash. A lost reply from `ota apply`/`rollback`
  is an unknown outcome, decided by re-login and the reported image hash.
  The transfer screen shows a rate-based
  ETA (ops applied / elapsed) once a few ops land — never an airtime-only
  guess; the node is deaf during flash writes, so airtime is ~15x off.

### Radio plan rules

- A temporary preset is `tempradio <freq>,<bw>,<sf>,<cr>,<minutes>` on the
  repeater only. The companion is retuned directly over BLE/TCP with
  `CMD_SET_RADIO_PARAMS` (stock companion firmware has no `tempradio` CLI).
  The app arms 15-minute chunks and renews at a window boundary after 10
  minutes; two failed renewals pause the transfer so a resume arms a fresh
  chunk. At the end the app sends the live preset back to the node and tunes
  the companion directly. A tempradio window pauses radio2 on the node and
  the node resumes it when the window reverts.
- radio2 is `radio2 <freq>,<bw>,<sf>,<cr>`; the node's primary keeps serving
  the mesh and the companion is moved to the secondary for the transfer. It
  must not overlap the live band (half of each bandwidth plus the 6 kHz
  guard) and must be scannable — the node validates; the app mirrors the
  overlap rule and surfaces the node's refusal.
- If radio2 is already enabled, do **not** reconfigure it: the firmware
  reports its preset in `radio2 status` (`preset=f,bw,sf,cr`), the radio screen
  shows it read-only, the app tunes only the companion, and the node's
  configuration is left alone. If the app enabled radio2 for the update, it
  turns it off again afterwards.
- The repeater's CLI defers the retune ~2 s so its reply leaves first; wait
  ~3 s after arming the plan before sending ops. The companion's direct radio
  write applies immediately.
- Restore the radios **before** the operator commits: apply and verification
  belong on the live mesh.

## Development and verification

Flutter stable / Dart are expected on `PATH`.

Run all checks from the repo root:

```sh
./scripts/check.sh      # format, analyze, all package + app tests
./scripts/coverage.sh   # the same with coverage; coverage_baseline.json is the gate
```

`DART` / `FLUTTER` override the executables. CI runs both, then builds the
APKs and the Linux/Windows/macOS desktop bundles.

New source files need ≥80% line coverage, and an existing file may not lose
covered lines. Regenerate the baseline with
`./scripts/coverage.sh --write-baseline` only after landing real coverage
gains. Every behavior change needs tests added in the same commit; every bug
fix needs a test that reproduces it.

The app's widget tests must not touch platform plugins or the network. Use
`test/support.dart` (`FakeLibrary`, fixture `Catalog`/`OtaStatus`/`OtaNodeInfo`)
and pump screens with a populated `AppState` — path_provider and HTTP are not
available in the test binding, and a real I/O call hangs the fake-async zone.

The user guide's screenshots are captured from the real widget tree by an
integration test (a `flutter test` golden would render placeholder text), on
an attached device. Add a `_Shot` to `app/integration_test/guide_screenshots_test.dart`
when a screen is added to the guide, then regenerate:

```sh
./scripts/screenshots.sh                 # 860x1864 PNGs -> docs/images/
./scripts/screenshots.sh --device <id>   # pick a device (default: linux)
./scripts/screenshots.sh --check         # verify every README embed exists
```

When the wire contract or the firmware side changes, run the fork's native
suite too:

```sh
cd ../MeshCore && pio test -e native_ota
```

The app icon is `app/assets/icon/icon.svg` (source). Render it and regenerate
every platform target (Android, macOS, Windows) with one command:

```sh
./scripts/icons.sh          # icon.svg -> icon.png, then flutter_launcher_icons
./scripts/icons.sh --check  # verify every generated target exists
```

## Protocol constraints and known gotchas

- Companion transport frames are `'<'` + uint16 LE length + payload inbound
  and `'>' + uint16 LE length + payload` outbound. The 1.18 `MAX_FRAME_SIZE`
  is **176 payload bytes** excluding the 3-byte TCP header. BLE NUS carries a
  raw payload per write/notify, also ≤176. A command over the frame limit is
  silently dropped by the companion — an oversized op is a stalled transfer,
  not an error. `otaLiteralChunkForBinaryReq()` derives the chunk size.
- `SELF_INFO` and `CMD_SET_RADIO_PARAMS` frequency fields are in **kHz** on
  the wire, while bandwidth is in **Hz**. `RadioParams.frequencyHz` is
  normalized to Hz; the CLI (`get radio`, `tempradio`, `radio2`) uses MHz and
  kHz strings. Convert only at the boundaries.
- `CMD_DEVICE_QUERY` reports `max_contacts / 2` in one byte; the client clamps
  its reported contacts.
- `app_target_ver >= 3` selects the V3 direct/channel message response layout;
  preserve the value sent by the client in `DEVICE_QUERY`.
- `PUSH_CODE_LOG_RX_DATA (0x88)` is `[code][snr*4][rssi][raw on-air packet]`.
- A message-sync pump drains unrelated queued messages before a CLI reply;
  `remoteCli` filters by sender prefix and text type, and `drainMessages()`
  clears stale replies at session start.
- Android BLE display names: prefer `ScanResult.advertisementData.advName`
  over `platformName` (a stale MAC-derived GAP cache).
- Never log private identity key material. The app holds no repeater keys;
  the admin password is session-only and never persisted.
- A transfer can be minutes long and the mesh can lose a reply. Treat
  uncertainty as unknown, never as success; verify by re-reading the node.

## Bench/live-mesh coupling

- The bench drives real radios through TCP companions; zero-hop and
  multi-hop (`--path`) are both supported.
- When running against the live mesh, keep traffic minimal: read-only
  `probe`, one-byte stage/abort cycles, and DIRECT paths when possible.
  Restore the companion's contact path to zero-hop when done.
- Live-mesh tests leak into the fork's hardware — a failed flash is
  recoverable via `ota rollback` on-device, but leave the node idle and on its
  last-good image when finished.

## Change and git discipline

- Work on `main` here (this repo is mine). Commit format/analyze/test-green
  only. One concern per commit; conventional prefixes (`feat:`, `fix:`,
  `docs:`, `ci:`, `refactor:`).
- Keep changes focused and match the surrounding Dart/Flutter style
  (`dart format`). Do not upgrade dependencies as drive-by work.
- Update `CHANGELOG.md` for every user-visible behavior, and the README when
  the user-facing flow changes; `docs/releasing.md` when the pipeline changes.
- Do not create a GitHub issue, PR, release, or publish artifacts without
  Jason's explicit request. Pushing code to the personal repo is allowed when
  Jason explicitly requests it.
- The fork (`MeshCore/examples/simple_repeater/OtaUpdate.*`) is a PRIME-time
  fork: keep fork changes minimal, and always run the native OTA tests and
  the app gates together.
- Tags `x.y.z` cut releases (see `docs/releasing.md`).
