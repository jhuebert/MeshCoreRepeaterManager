# Agent Guide: MeshCoreRepeaterManager

## Project & ownership

Standalone Android-first Flutter/Dart app that pushes firmware updates to
MeshCore repeaters over LoRa through a stock companion device. The app talks to
the companion over BLE or TCP and uses it purely as a radio. The encrypted OTA
ops ride the same REQ/RESPONSE path as an admin `ota status` request. The app and
product name is **MeshCoreRepeaterManager**. iOS is deferred until there is
hardware to test on; Windows, macOS and Linux desktop builds use the same TCP
path.

This is a personal project under `jhuebert/MeshCoreRepeaterManager`. The
repeater side of the feature lives in the `lora-ota` branch of
`jhuebert/MeshCore` (`examples/simple_repeater/OtaUpdate.*`), and the two halves
must stay in sync. The reference repos in the workspace (`MeshCore/`,
`MeshChameleon/`, `openhop_core/`) are read-only: do not edit them as part of
this project. `mesh_protocol`, `device_link` and `test_support` are reused from
MeshChameleon via `git subtree`; prefer fixing bugs upstream there, through the
subtree, over diverging; retain MIT attribution and keep `ATTRIBUTION.md`
accurate.

## Agent conduct

These rules apply to every change, including documentation-only changes.

- **Ask before codifying a pattern.** When a way of working recurs (a convention
  applied more than once, a preference stated twice, a pattern from a finished
  change), propose wording plus a one-line rationale and ask before adding it
  here. Never follow an unwritten rule silently, and never edit this file on
  your own initiative.
- **Commit only when asked.** Commit when Jason asks or clearly wants one. Never
  bundle unrelated cleanup with an implementation commit.
- **Ask before publishing.** Do not create a GitHub issue, PR, release, tag, or
  published artifact, or push to a remote without Jason's explicit request.
  Pushing to the personal repo is allowed only when Jason explicitly requests
  it.
- **No em dashes anywhere.** In this guide, project docs, code comments, commit
  messages, CLI text and replies, and all UI text or user-facing strings. Use a
  short sentence, a colon or a comma instead. Replace one on any line you touch.
- **Minimum viable change.** The smallest diff that fully fixes the problem: no
  drive-by refactors, renames, reformatting of untouched lines, or dependency
  upgrades folded into unrelated work. Re-read the final diff and confirm every
  touched line is required and nothing else changed.
- **DRY.** Shared logic gets one authoritative home, and nothing re-implements
  it. If you find yourself copying a block from a sibling function, factor it
  instead.
- **Deslop as you go.** Code you touch ends up cleaner than you found it where
  slop is in reach: duplicated logic factored, unbounded writes bounded, dead
  state removed, twin branches merged. Remove unimplemented stubs and dead code
  before calling the change done. Do not deslop code you are not otherwise
  touching; that is churn, not cleanliness.
- **Simplicity and maintainability.** The simplest correct code; obvious beats
  clever; write what the project's maintainers would have written. Comments
  explain why, not what. Choose solutions that stay workable so later features
  are easy to add.
- **Guide durability.** This guide holds durable rules and pointers, not
  volatile state: no test counts, current coverage figures, version or date
  stamps, churn statistics, growing suite or target inventories, or planned
  work. Point to the file that owns the current value. Keep a numeric constant
  only when it encodes a frozen contract, and name its authoritative source.
- **Honesty about validation.** Do not claim hardware validation unless it was
  run against real hardware. State what was bench-verified and what remains
  empirical.

## Start here: docs & code map

1. Read `README.md` (the user guide) and this file. `SECURITY.md` has the threat
   model, `CHANGELOG.md` every user-visible change, and `docs/releasing.md` the
   release procedure.
2. Check `git status` before editing and leave unrelated work alone.
3. Inspect the relevant package code and the fork's `OtaUpdate.h` before
   changing anything that touches the wire contract.
4. The offline library and settings are persisted user data. A layout change
   must migrate the previous format and be tested with old-format fixtures;
   never silently discard images or the offline flag. See *Compatibility &
   frozen contracts*.

**Repository layout:**

- `app/`: Flutter UI, screens, orchestration, theme, app icon and desktop
  runners (Android, Linux, Windows, macOS).
- `app/test/`: widget and pure-Dart app tests. `support.dart` has the shared
  fixtures (`FakeLibrary`, `Catalog`, `OtaStatus`/`OtaNodeInfo`); use it for
  every screen test instead of touching platform plugins.
- `packages/ota_core/`: wire contract (op frames, CRC), the frozen `ota status`
  CLI-line parser, `OP_INFO` parsing, the delta engine (rolling-hash matcher),
  the windowed transfer engine (REQ/RESPONSE, op retry from `next_expected`),
  and the frozen `ota net` parser for observer downloads.
- `packages/wifi_ota_core/`: pure-Dart AsyncElegantOTA client with injectable
  HTTP client, MD5 helper and multipart upload. Original work, MIT.
- `packages/mesh_protocol/`: pure-Dart protocol constants, codecs, identity,
  crypto, packet models and builders (MeshChameleon subtree).
- `packages/device_link/`: pure-Dart `RadioLink` SPI, TCP/BLE/fake transports,
  binary requests (MeshChameleon subtree).
- `packages/companion_client/`: contacts, login, `remoteCli`, message pump.
- `packages/test_support/`: dev-only framed TCP client and test plumbing
  (MeshChameleon subtree).
- `bench/`: hardware harness, never run in CI: `--scenario
  probe|measure|full|delta|reject|cancel|rollback`.
- `scripts/check.sh`: full analysis and test gate; `scripts/coverage.sh` adds
  the coverage gate; `scripts/build.sh` injects build metadata.
- `.github/workflows/ci.yml`: the gate plus platform builds;
  `release.yml`: the manual signed release.

Keep protocol/core packages free of Flutter or platform imports. Platform code
belongs in `app/`.

The authoritative firmware spec is `MeshCore/examples/simple_repeater/OtaUpdate.h`;
`packages/ota_core/lib/src/wire.dart` mirrors it, not the other way around.
Stock companion framing and limits come from
`MeshCore/docs/companion_protocol.md` and the pinned stock firmware in
`MeshCore/examples/companion_radio/`.

## Current state & next milestone

The full flow is implemented and hardware-exercised: connect, pick a repeater,
admin/ACL login, `OP_INFO` handshake, board-scoped version picker, delta or
full-image staging, windowed transfer, `ota apply`, post-reboot verification and
`ota rollback`. The app also carries a version-based offline library and a
three-way radio plan (live mesh, temporary private preset, the repeater's
radio2). The diff is computed by the repeater hashing its own running image, so
no previous image is needed on the device. Release version strings are labels
for the offline library only, never diff inputs. `FirmwareLibrary.findBaseForSha`
and `findBaseFor` are legacy helpers with no production caller; do not
reintroduce a base picker or base matching.

The Radio step also chooses among three update paths: LoRa (the original
pipeline), the ESP32 update page over WiFi, and a direct download performed by
an observer repeater. WiFi modes are mutually exclusive and decided from
read-only facts before `start ota` is sent, so the sign-in probe never opens a
web server. A stock ESP32 repeater can take a WiFi hotspot update after a
fallback sign-in that skips the OTA handshake; its result is a version match,
not a hash match. Observer downloads use `ota fetch ver`/`sha`/`start` and
`ota net`, then converge on the same `ota apply` commit as LoRa. The large
repeater-management branch is reference work only; this line of work copies
just the small WiFi helpers from it.

Fork release naming has no `filter`: tags and firmware stamps use `v<version>`,
titles use `Firmware <version>`, and app-slot assets are `<env>-v<version>.bin`.
Old `filter-v*` tags and `-filter-<sha>` names are not accepted; a one-time
startup pass drops saved library entries that still carry them.

Explicitly deferred: iOS (needs hardware); refusing a release older than the OTA
feature (there are no such releases in the field yet, so the check has nothing
to test against); macOS/Windows code signing and notarization (builds are
unsigned and users bypass Gatekeeper/SmartScreen explicitly).

Do not claim hardware validation unless it was run against real hardware.
Transfer robustness, radio restore and boot rollback have been exercised on the
bench; long multi-hop transfers in the field remain empirical.

## Parity & intentional differences

- The companion is **stock**. Do not require custom companion firmware or a new
  payload type. The app uses `CMD_SEND_BINARY_REQ` (the same path as a status
  request), `CMD_SEND_LOGIN`, `CMD_SEND_TXT_MSG` and `CMD_RUN_CLI_COMMAND` as
  shipped.
- Match `MeshCore/docs/companion_protocol.md` and the pinned stock firmware for
  frame layouts, command lengths, response codes and limits.
- Firmware parity for the target node is the fork's `OtaUpdate.h`: the app is a
  client of that contract, not a second implementation of it.

### Known intentional differences

- A blank admin password is sent as a valid login. Stock firmware treats a
  blank password as "is this key already in my ACL?"; the app exposes that
  instead of refusing empty input.
- The app re-reads and re-sends `tempradio` on the companion to restore it early
  rather than waiting out the timer. The command is stock CLI.
- The picker scopes to the node's reported board, even though a user may
  deliberately choose another board (the node refuses a mismatch at staging).
- The offline library stores whole versions (all boards), not a per-device
  selection. That is the product decision, not a protocol constraint.

## Compatibility & frozen contracts

### Persisted data

The offline library and settings are persisted user data. A layout change must
include a migration from the previous format and tests with old-format
fixtures. Never silently discard images or the offline flag. Migration support
is temporary, not permanent: once the field has moved, the old path can be
removed in one excision.

### OTA wire contract stability rules

`packages/ota_core/lib/src/wire.dart` mirrors `OtaUpdate.h`; the header is the
authoritative spec.

- The op stream rides inside ordinary admin REQ/RESPONSE datagrams:
  `[tag(4)][REQ_TYPE_OTA (1)][frame_len(1)][OTA frame]`. The crypto layer
  zero-pads the plaintext to a 16-byte block, hence `frame_len`: the node
  slices exactly that many bytes and ignores the padding. Nothing else about
  the frame is negotiated. Magic `O`,`T`, CRC-16/CCITT-FALSE, frozen CRC and op
  order are fixed.
- `OP_INFO` (0x07) is the capability handshake, answered in every state.
  `OP_INFO_REPORT` (0x08) carries wire version, target id, slot size,
  `max_literal`, the feature bits (`supportsDelta`, `supportsApply`), the
  running firmware version (NUL-padded 32 bytes) and the **running image's
  SHA-256**, taken over exactly the bytes an update wrote (image length from the
  ESP image header, appended digest included), so it equals the hash of the
  app's own `.bin`. It is still used for post-reboot verification, but the app
  no longer needs a local image matching it: `OP_BLOCK_HASH` (0x09/0x0A,
  feature bit `0x00000004`) hashes ranges of the running image, and
  `OP_BLOCK_FIND` (0x0B/0x0C) locates up to twelve 64-bit rolling fingerprints
  in one scan of a window of it. Matches are found by content, not offset.
  `OP_LITERAL_Z` (0x0D) carries a chunked raw-DEFLATE stream of new bytes; the
  node inflates it with ESP32 ROM miniz into the staged slot. The app compresses
  at level 9 with `dart:io`'s GZipCodec minus its wrapper. All zeros means
  "cannot tell" (no readable image).
- `target id` is the **build environment** id (first four bytes of
  `sha256(pio_env)`), not a hardware id. The app maps it back to an environment
  by hashing the names it knows from the catalog and library. Flashing a node
  with another variant of the same board (observer versus plain) is refused by
  the node and by `stage()`; switch variants over USB/WiFi, not OTA.
- `max_literal` counts the REQ envelope: `REQ_TYPE_OTA`, `frame_len`, the op
  frame overhead and the literal's length word all come out of one
  `MAX_PACKET_PAYLOAD` datagram. `OtaUpdate.h` owns the current sizes.
- `PUSH_CODE_BINARY_RESPONSE` (0x8C) payloads arrive zero-padded to a 16-byte
  block; `unpadFrame()` trims them by CRC, so a report whose CRC ends in `0x00`
  still parses. Two record layouts exist (tag first, or pubkey prefix then
  tag); both are accepted, and the tag-at-2 candidate must frame before it is
  believed.
- New ops get new codes; existing ops never change meaning, field order or
  size; the SEQ rules and CRC are frozen. A hard break is a new REQ code, never
  a silent redefinition.
- `REQ_TYPE_OTA` is `0xA0`, a fork-private REQ code above upstream's
  `0x01..0x09` range (`0x08` is upstream's `subscribe`). Keep the app's
  `reqTypeOta` in sync with the repeater's constant; changing one alone breaks
  every update session.
- Unknown ops are dropped silently. A stray unknown op **inside a staged stream
  aborts staging**, deliberately.

### Frozen terminology

Do not reintroduce transport bindings ("wire v2") in docs or comments. Nodes in
the field predate any release, so this transport IS the format. Refer to it as
the OTA wire contract.

## Principle of least surprise

The UI/UX must be **maximally consistent across the whole app**: same glyphs,
button labels, phrasing, spacing and formatting for the same idea on every
screen. Shared building blocks live in `app/lib/widgets/common.dart`. Design
for the principle of least surprise: an operator who has never read the docs
should be able to predict what each control does and what happens next. Follow
familiar platform conventions, favour ease of use, easy visual scanning and
visual appeal over cleverness, and keep text plain and user-centric. Primary
action buttons are short names with a single monochrome Material icon in front
(next, play, pause, stop, back), never a long label with an explanation
appended. Shared `IconData` constants live in `app/lib/widgets/common.dart`; do
not use colored emoji as button icons.

The flow is linear: an action that belongs on the next screen does not belong
below the fold on the current one. One screen, one main action: secondary
buttons are text/outlined and rarely more than one is a filled button. The UI
is for operators with no MeshCore or protocol knowledge, so keep copy
user-centric and jargon only where it is accounted for (`radio2`, `tempradio`
on the node CLI itself). The current screen sequence lives in `README.md`, not
here.

Stable UX invariants:

- Every screen carries `WizardBar` (step and label); the next action lives in a
  `WizardFooter` or an equivalent bottom bar.
- Connecting lands the operator on the repeater step by itself. The sign-in
  button is always tappable and successful sign-in advances by itself; the step
  bar is the way back. There is no separate check button.
- Versions are the unit on the firmware screen: one row per version, no board
  dropdown and no per-device rows. The app detects the board and downloads that
  board's image just when a version is tapped. Releases with no image for the
  detected board are hidden. The save button downloads all assets of a release;
  the cloud icon shows save state and the trash icon deletes the whole version.
  There is no Offline tab: offline mode shows only saved versions in the GitHub
  tab. Imported `.bin` files live on their own tab, are selected as the image to
  install, and are never a local delta base. The Firmware library on the main
  screen is the same screen in manager mode. The offline switch is persisted and
  prevents every GitHub request, catalog included.
- The radio screen shows both current radio settings, including radio2's preset
  when enabled, has no duration input (the repeater's temporary window is
  renewed in fixed chunks), shows plan validation before Next, and never
  continues with an invalid plan. Tempradio warns that an enabled radio2 is
  paused.
- Review summarizes companion and connection, repeater name and board, current
  firmware, firmware to install, image size and radio choice. No transfer time
  is guessed before the comparison; the exact comparison starts on Transfer
  after Start, and the live rate-based ETA appears there once ops land. Never
  start with an invalid plan.
- Transfer's first phase is the comparison, armed **after** the chosen radio
  plan so its many REQ/RESPONSE queries never go over the live mesh when an
  off-mesh channel was selected. Show progress and allow a stop that restores
  the radios. Stop before staging on an identical image. No screen claims
  success until the node answers with the newly sent image's hash. A lost reply
  from `ota apply`/`rollback` is an unknown outcome, decided by re-login and
  the reported hash. The ETA is rate-based (ops applied / elapsed), never an
  airtime-only guess: the node is deaf during flash writes, so airtime is far
  off.
- Repeater and manual-public-key entry are separate tabs. A long contact list
  must never hide the key field or the admin login. When signed in, the
  password card is hidden and the screen shows node facts only.

## Domain rules

### Radio plan rules

- A temporary preset is `tempradio <freq>,<bw>,<sf>,<cr>,<minutes>` on the
  repeater only. The companion is retuned directly over BLE/TCP with
  `CMD_SET_RADIO_PARAMS` (stock companion firmware has no `tempradio` CLI).
  The app arms 15-minute chunks and renews at a window boundary after 10
  minutes; two failed renewals pause the transfer so a resume arms a fresh
  chunk. At the end the app sends the live preset back to the node and tunes
  the companion directly. A tempradio window pauses radio2 on the node, and the
  node resumes it when the window reverts.
- radio2 is `radio2 <freq>,<bw>,<sf>,<cr>`; the node's primary keeps serving the
  mesh and the companion moves to the secondary for the transfer. It must not
  overlap the live band (half of each bandwidth plus the 6 kHz guard) and must
  be scannable. The node validates; the app mirrors the overlap rule and
  surfaces the node's refusal.
- If radio2 is already enabled, do **not** reconfigure it: the firmware reports
  its preset in `radio2 status`, the radio screen shows it read-only, the app
  tunes only the companion, and the node's configuration is left alone. If the
  app enabled radio2 for the update, it turns it off again afterwards.
- The repeater's CLI defers the retune about two seconds so its reply leaves
  first; wait about three seconds after arming the plan before sending ops.
  The companion's direct radio write applies immediately.
- Restore the radios **before** the operator commits: apply and verification
  belong on the live mesh.

### Protocol constraints and known gotchas

- Companion transport frames are `'<'` plus uint16 LE length plus payload
  inbound and `'>'` plus uint16 LE length plus payload outbound. The pinned
  firmware's `MAX_FRAME_SIZE` limits payload bytes excluding the 3-byte TCP
  header. BLE NUS carries a raw payload per write/notify, with the same limit. A
  command over the frame limit is silently dropped by the companion, so an
  oversized op is a stalled transfer, not an error.
  `otaLiteralChunkForBinaryReq()` derives the chunk size. `OtaUpdate.h` and the
  pinned companion firmware own the current numbers.
- `SELF_INFO` and `CMD_SET_RADIO_PARAMS` frequency fields are in **kHz** on the
  wire, while bandwidth is in **Hz**. `RadioParams.frequencyHz` is normalized to
  Hz; the CLI (`get radio`, `tempradio`, `radio2`) uses MHz and kHz strings.
  Convert only at the boundaries.
- `CMD_DEVICE_QUERY` reports `max_contacts / 2` in one byte; the client clamps
  its reported contacts.
- `app_target_ver >= 3` selects the V3 direct/channel message response layout;
  preserve the value sent by the client in `DEVICE_QUERY`. `APP_START` bytes
  1 through 7 are reserved and must not override it.
- `PUSH_CODE_LOG_RX_DATA (0x88)` is `[code][snr*4][rssi][raw on-air packet]`.
- A message-sync pump drains unrelated queued messages before a CLI reply;
  `remoteCli` filters by sender prefix and text type, and `drainMessages()`
  clears stale replies at session start.
- Android BLE display names: prefer `ScanResult.advertisementData.advName` over
  `platformName` (a stale MAC-derived GAP cache).
- Never log private identity key material. The app holds no repeater keys; the
  admin password is session-only and never persisted.
- A transfer can be minutes long and the mesh can lose a reply. Treat
  uncertainty as unknown, never as success, and verify by re-reading the node.

### Bench/live-mesh coupling

- The bench drives real radios through TCP companions; zero-hop and multi-hop
  (`--path`) are both supported.
- When running against the live mesh, keep traffic minimal: read-only `probe`,
  one-byte stage/abort cycles and DIRECT paths when possible. Restore the
  companion's contact path to zero-hop when done.
- Live-mesh tests leak into the fork's hardware. A failed flash is recoverable
  with `ota rollback` on-device, but leave the node idle and on its last-good
  image when finished.

## Verification

Flutter stable / Dart are expected on `PATH`.

- Run all checks from the repo root: `./scripts/check.sh` (format, analyze, all
  package and app tests) and `./scripts/coverage.sh` (the same with coverage).
  `DART` and `FLUTTER` override the executables. CI runs both, then builds the
  APKs and the desktop bundles. `check.sh --no-tests` runs only the format and
  analysis gates so the suite is not run twice.
- `coverage_baseline.json` is the coverage gate. New source files need at least
  80% line coverage, and an existing file may not lose covered lines. Regenerate
  the baseline with `./scripts/coverage.sh --write-baseline` only after landing
  real coverage gains. Do not record current coverage numbers in this guide.
- Every behavior change needs tests added in the same commit. Every bug fix
  needs a test that reproduces it. Pure refactors keep the suites green
  unchanged: the suites are the safety net that proves no behavior slipped.
- Widget tests must not touch platform plugins or the network. Use
  `app/test/support.dart` fixtures and pump screens with a populated
  `AppState`; `path_provider` and HTTP are not available in the test binding,
  and a real I/O call hangs the fake-async zone.
- Guide screenshots are captured from the real widget tree by an integration
  test on an attached device (a `flutter test` golden renders placeholder
  text). Add a `_Shot` to `app/integration_test/guide_screenshots_test.dart`
  when a screen is added to the guide, then regenerate with
  `./scripts/screenshots.sh`; `--device <id>` picks a device and `--check`
  verifies every README embed exists.
- The app icon source is `app/assets/icon/icon.svg`. Render it and regenerate
  every platform target with `./scripts/icons.sh`; `--check` verifies every
  generated target exists.
- When the wire contract or firmware side changes, run the repeater side's
  native OTA suite in `../MeshCore` (its `build.sh` owns the commands) together
  with the app gates. Fork changes on the repeater side stay minimal.

## Change & git discipline

- Work on `main` here (this repo is mine). Commit format, analyze and test green
  only. One concern per commit; conventional prefixes (`feat:`, `fix:`,
  `docs:`, `ci:`, `refactor:`).
- Keep changes focused and match the surrounding Dart/Flutter style
  (`dart format`). Do not upgrade dependencies as drive-by work.
- Update `CHANGELOG.md` for every user-visible behavior, `README.md` when the
  user-facing flow changes, and `docs/releasing.md` when the pipeline changes,
  in the same commit.
- Do not create a GitHub issue, PR, release, or publish artifacts without
  Jason's explicit request. Pushing code to the personal repo is allowed only
  when Jason explicitly requests it.
- The fork (`MeshCore/examples/simple_repeater/OtaUpdate.*`) is a PRIME-time
  fork: keep fork changes minimal and always run the native OTA tests and the
  app gates together.
- Tags `x.y.z` cut releases; see `docs/releasing.md` for the procedure.
