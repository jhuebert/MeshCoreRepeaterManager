# Changelog

All notable changes to MeshCoreRepeaterManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **The app now uses the fork's new firmware release names.** Versions are
  listed as `v<version>` instead of `filter-v<version>`, and release assets are
  named `<env>-v<version>.bin` without the old `-filter-<sha>` suffix. Old
  `filter` releases and assets are ignored. This does not change how updates
  are computed: the repeater still hashes its own running image to build the
  diff, so no old firmware file is needed on the device.
- **Saved firmware with old names is deleted once on first launch.** Only
  library entries whose version or file name contains the retired `filter`
  marker are removed; imported files with ordinary names and the offline
  setting are kept. A saved update is discarded only if it pointed at a
  deleted image or used an old version label. Those versions must be
  downloaded again.

## [1.1.1] - 2026-11-22

later

### Fixed

- **A foreground-service start timeout no longer blocks an update.** The
  plugin polls its service state every 100 ms for five seconds after
  `startService`, and on a busy device that poll can delay the service's own
  start and report a false `ServiceTimeoutException`. The app now skips that
  unreliable poll, so a transfer starts immediately; real start failures, such
  as a background start the OS refuses, are still surfaced to the Updating
  screen.

## [1.1.0] - 2026-11-21

Later

### Added

- **The temporary channel renews itself.** The repeater arms `tempradio` in
  15-minute chunks and the app renews it automatically at a transfer window
  boundary after 10 minutes, so there is no duration to set and no window to
  expire mid-update. Two failed renewals pause the transfer; continuing arms
  a fresh chunk from the saved position.
- **The radio screen shows the repeater's current settings**, including the
  radio2 preset when it is enabled. An enabled radio2 is used as-is instead of
  asking the operator to re-enter it, and the screen warns that a temporary
  channel pauses radio2 while it is active.
- **Android transfers keep the screen on and survive the Home screen.** A
  foreground notification now shows op progress, and the same guard covers
  apply and rollback. If the foreground service cannot start, the update
  refuses to begin instead of silently running without it.

- **Transfers can be paused mid-upload.** The transfer screen's Pause button
  keeps the repeater's staged bytes and the saved op stream, records the last
  known position, and returns to the Connect screen with the update ready to
  continue. Nothing is aborted or applied.
- **Interrupted updates can be resumed.** The app now saves the target image
  and the exact op stream when a transfer starts. After a crash or a rebooted
  phone, an **Unfinished update** row on the Connect screen opens a recovery
  screen: sign in again, check how much the repeater received, and continue
  from there without re-uploading it. If the upload had already finished, the
  recovery screen offers to commit it. Cancel resume discards the staged image
  and lets you pick a different firmware. The admin password is never stored.
  If the repeater itself reboots, its staged bytes are gone and the upload must
  start over, but the saved firmware image is reused.

### Changed

- **The app icon now shows a settings gear at the centre of the mesh.**
  The down arrow read as "OTA update only"; the gear reflects that the app
  manages repeaters. Every platform icon and the guide screenshots were
  regenerated from the new SVG source.
- **A consistent, plain-language interface across every screen.** Primary
  buttons are now short names with one monochrome action icon (arrow for next,
  play to start or resume, pause, stop, back), themed to match the app and
  with no descriptions appended. The Connect screen is titled "Repeater Manager", connection and
  Bluetooth failures are short and actionable, and the Connect button shows a
  spinner and "Connecting…" while it works. Radio settings no longer has a
  region-specific "Suggest settings" button: the private preset is filled in
  from the repeater's own settings and stays editable. Review shows only the
  facts known before Start. Transfer shows a determinate bar with the percent
  on the right, "X / total sent · re-sends · X min left" on one line, with no
  ops/s or packet count. An up-to-date result is a terminal 100% state, and
  the active Transfer step uses a circular progress ring. The Imported tab shows the selected
  image's size, not a guessed "full" or "remote diff" label. Dialog "Keep",
  "Cancel" and "Close" actions are proper outlined buttons. No UI text uses
  em dashes.
- **No transfer time is guessed before the comparison.** The radio and review
  screens no longer show inflated worst-case estimates, and the compare phase
  on Transfer uses only exchange counters — the main progress bar and the
  rate-based ETA cover the rest of the run.
- **The firmware comparison now runs on the channel you chose.** It is no
  longer a standalone step before Radio: after **Start update**, the Transfer
  screen arms the selected radio plan first and then compares the repeater's
  running image on that channel, so its many exchanges never go over the live
  mesh when a private channel or radio2 was chosen. The wizard is now eight
  steps; Review shows the plan and the radio choice instead of reuse numbers
  that do not exist yet. An identical image stops on Transfer before staging,
  and stopping a comparison restores the radios.
- **A lost `ota apply` is no longer reported as a bad image.** The app reads
  `ota status` after an unacknowledged apply: a still-verified staged slot
  means the command did not get through, so it retries the apply (up to three
  attempts) without transferring anything again. The saved update is kept
  until verification actually succeeds, and the verify screen offers **Try
  applying again** instead of claiming the new firmware is broken.
- **Resuming is now verified against the repeater, not just its status line.**
  Firmware with the new capability API reports a per-session id and a
  structured upload position, so the app can tell a phone restart from a
  repeater restart and reads back the staged bytes to confirm they match the
  saved image before sending the rest. It also checks the node's codec support
  before compressing and logs a best-effort link check before arming; all of
  these fall back to the existing behaviour on older firmware.
- **Updates transfer faster and Compare no longer times out on slower nodes.**
  The repeater now bulk-reads its running image during block searches instead
  of one 4-byte read per step — a 128 KB scan dropped from ~8 s to under 1 s on
  the Xiao S3. The app compares in 1 KB blocks over 32 KB windows (four times
  fewer exchanges than 256-byte blocks, at only a few percent less reuse) and
  transfers in 16-op windows with tighter pacing. On real hardware an r3→r4
  comparison fell from ~5 minutes to ~75 seconds with no loss of reliability.
- **Literal bytes are now compressed over the wire.** Consecutive new bytes are
  DEFLATE-compressed at level 9 by the app (raw stream, no gzip wrapper) and
  sent as `OP_LITERAL_Z` chunks; the node inflates them with the ESP32's ROM
  miniz straight into the staging slot. On the real r3→r4 binaries the literal
  stream shrinks to about 70% of its raw size, so a diff now sends roughly half
  of the image instead of 69%. COPY ops, seq numbering and the node's SHA-256
  gate are unchanged; a corrupt or truncated compressed stream fails staging
  with `err=9` instead of producing a wrong image.
- **Updates are now diffs against the repeater's running firmware, computed on
  the repeater.** A new **Compare** step (5 of 9) uses two read-only ops.
  `OP_BLOCK_HASH` reports the running image's size, ESP segment table and
  whole-image hash (and hashes up to four ranges per exchange). `OP_BLOCK_FIND`
  sends up to twelve 64-bit rolling fingerprints in one request; the node slides
  them once over a window of its running image and returns where each block
  occurs. Matching blocks become `OP_COPY`s from the exact offset, changed
  blocks become literals. Because matches are located by content, not by
  offset, an inserted or removed byte no longer costs the rest of the image:
  on real `filter-v1.18.0-r2/r3/r4` binaries the remote diff sends about 69% of
  an image in ~470 exchanges (256-byte blocks), versus 100% for a full image.
  You no longer need the previous firmware on your device, and an identical
  image is detected in one exchange with nothing sent. The old local
  rolling-hash matcher, delta-base matching, "Use as delta base" and the
  full-image override are gone. The new step is read-only and is a safe place
  to stop: staging still starts only from Review.
- **The wizard is nine steps** (Connect, Repeater, Sign in, Firmware, Compare,
  Radio, Review, Transfer, Verify). Firmware now continues to Compare.

### Fixed

- **Choose firmware no longer skips straight to Review.** When the radio
  settings step was introduced the firmware step kept its old "Review update"
  button; it now continues through Compare to Radio settings.
- **A renamed or generic `.bin` can be selected without a board name.** When
  the repeater did not answer the capability check, an imported image whose
  file name has no board was stuck behind a dead-end warning. The app now
  retries the handshake with a longer timeout, then offers a **Choose board**
  action. No board is guessed from a file name or a hash — the repeater's own
  reported target id is the only authority.
- **The Android app no longer dies immediately on launch.** The manifest
  resolved the launcher activity against the app's applicationId, but the
  Kotlin class was declared in a different Gradle namespace. The APK built
  and installed cleanly, then crashed with `ClassNotFoundException` before
  Flutter started. The activity now lives in the namespace the manifest
  resolves against, and a test keeps the two in sync.


- **A version can now be selected when the repeater does not answer its
  capability handshake.** When the Sign in screen shows **Board: unknown**,
  the firmware picker still listed GitHub versions but left every row
  untappable, so the downloaded image could never be chosen. Tapping a version
  now offers the images in that release to pick from explicitly (the online
  and offline views both work), and a note on the picker explains why the
  choice is manual. Auto-detection is unchanged when the node does report its
  board.

### Changed

- **The step progress bar now sits directly below the title and back arrow on
  screens with tabs.** On **Pick a repeater** and **Choose firmware** the bar
  used to appear below the Repeaters/Public key and GitHub/Imported tabs; it
  is now above them, matching every other wizard step. The guide screenshots
  for those steps were regenerated.
- **The app icon is now a connected mesh delivering a firmware update to its
  centre node**, replacing the repeater-mast-and-loop mark. Every platform
  target (Android launcher and adaptive icons, the macOS app icon and the
  Windows `.ico`) is regenerated from the new SVG source.

### Fixed

- **Resuming an update no longer fails with a staged-bytes error.** The staged
  prefix check asked the repeater to hash the whole upload in one range, but
  the firmware caps a hash range at 32 KB, so every real resume was refused.
  It now hashes in 32 KB chunks, two ranges per exchange: a four-range reply
  was too large for the companion's radio payload once its tag and public-key
  prefix were added, which showed up as "no answer from the node" on the live
  mesh. Staged queries also allow a longer reply window and more retries. An
  unavailable resume offers a real "Check again" instead of discarding the
  upload.
- **Importing a second `.bin` no longer replaces one with identical bytes.**
  Imports are identified by file name and content, so each imported file keeps
  its own row. Deleting one no longer deletes the other.
- **Bluetooth and connection failures are no longer raw technical errors** on
  the Connect screen.
- **The time left after a resume is no longer wildly optimistic.** The rate
  previously divided all ops the node reported, including the prefix uploaded
  before the pause, by the current run's elapsed time. It now measures only
  ops sent since the resume.

## [1.0.0] - 2026-11-17

1.0.0 — first signed release.

Installs are sideloaded from this release (no app store). Android APKs are signed with the project's app key so later releases install in place; desktop bundles are unsigned.

- Eight-step wizard: Connect → Repeater → Sign in → Firmware → Radio → Review → Transfer → Verify.
- Board-scoped firmware picker, version-based offline library, and imported `.bin` files.
- Three radio plans: live mesh with a DIRECT override, a temporary private preset, and the repeater's radio2.
- Delta or full-image transfer with an automatically matched base, a measured-rate ETA, and commit/verify by the running image's hash; the repeater rolls back a bad boot by itself.
- Bluetooth on Android, macOS and Linux; network (TCP/Wi-Fi) on every platform. Windows has no Bluetooth backend.
- Signed universal and per-ABI Android APKs, plus Linux, macOS and Windows desktop bundles.

### Changed

- **Bluetooth is available on macOS and Linux**, in addition to Android and
  iOS. Desktop still opens on TCP, but the Bluetooth option can be selected
  where the BLE plugin has a backend; Windows keeps TCP only because the
  plugin has no Windows implementation. The macOS build now declares the
  Bluetooth entitlement and usage description.

- **The wizard is now eight steps, finishing with a real review.** The old
  "Review update" step is now **Radio settings** — where the transfer runs,
  the suggested preset and a duration input that defaults to the recommended
  time (the "Use X min" button is gone), plus the live-mesh direct path
  override. A new **Review** step summarizes everything chosen before
  anything goes on air: the companion and how it is connected, the repeater
  and its board, the current firmware, the firmware to install, the image
  size, full-vs-delta and how much will be sent, an estimated time, and the
  radio choice. Transfer is step 7, Verify is step 8.
- **The review screen no longer offers a base picker.** The delta base is
  always matched automatically (running-image hash, then the version
  stamp); when there is no match the screen says the full image will be
  sent. The **Choose base** and **Change image** buttons are gone, along
  with the "what happens" and SHA-256 sections. On warnings, the board
  mismatch bullet is gone; the low-battery and phone-in-range bullets stay.
  A manual base override is still possible from the **Imported** tab
  (**Use as delta base** / **Clear delta base override**).
- **The firmware picker and library dropped the explanatory copy.** The
  release list lost the "Versions are treated as a unit…"/"Showing
  versions…" paragraph (the refresh icon stays), the "Showing the cached
  catalog" note is gone, and version rows no longer spell out "not
  downloaded"/"saved for offline use" — the cloud icon shows it (partial
  downloads still show a count). The **Dev builds** tab is now **Dev**.
- **Sign in uses one action.** The separate **Check node** button is gone:
  the bottom action signs in (always tappable, blank password allowed) and
  lands on the firmware step on success.
- **Quieter, plainer copy throughout.** Protocol terms were removed or
  renamed where they weren't needed ("Dev builds"→"Dev", the transfer step
  no longer mentions the windowed REQ stream, the integrity check is no
  longer called SHA-256 on screens, the Undo explainer section on the
  verify screen is gone, and "(ota rollback)" was dropped from the
  rollback button). The verified message now says the repeater came back
  on the new image hash instead of the version stamp. The connect screen
  lost its intro blurb and the TCP companion description was simplified;
  the public key tab lost the "manual node" sentence.

### Added

- **The signed test build covers all four platforms.** Alongside the signed
  Android APKs (universal and per-ABI, including x86_64), the test-build
  workflow now attaches Linux, macOS and Windows bundles to the workflow run
  so a candidate can be tried before a release is tagged.
- **The firmware library is now the firmware picker, usable on its own.**
  The screen reached from the main screen is the same one as step 4: the
  **GitHub** tab lists release versions one row each (with the cloud icons
  showing what is saved for offline use, and a trash icon per version), and
  the **Imported** tab holds imported `.bin` files — one row per file —
  with an import button. In the standalone view, tapping a version downloads
  all of its missing images; inside an update, tapping a version downloads
  only the image for this node's board and selects it. Deleting a version
  (all boards) or the selected image/delta base is repaired automatically.
  Downloaded versions and imported files are always separate.


- **A guided seven-step flow.** Connect → Repeater → Admin → Firmware →
  Review → Transfer → Verify, with the same step bar and bottom action on
  every screen. The admin login moved to its own step, and the repeater list
  and manual public key are separate tabs — a long contact list no longer
  hides the fields below it.
- **Optional admin password.** A blank login is valid: the repeater checks
  whether the companion's key is already an admin in its ACL, so no password
  is needed for a provisioned companion. `Check node` is never disabled for
  an empty password.
- **Board-matched version picker.** The node's `OP_INFO` target id is mapped
  back to its build environment, the GitHub listing shows only versions with
  an image for that board, and the app downloads that board's image for you —
  there is no board picker.
- **Stable and dev are separate tabs**, each newest-first with release dates
  (dev builds used to be a switch under one long list).
- **Version-based offline library.** Saving a version downloads every board's
  image of that release. A persistent **Go offline** switch on the firmware
  screen prevents *every* GitHub request, including the catalog, and shows
  only the saved versions.
- **Three radio plans.** Live mesh with the DIRECT path override; a temporary
  private preset on both the repeater and the companion; or the repeater's
  radio2 preset while the live mesh keeps running. Off-mesh modes are zero-hop,
  and a settings screen suggests a preset and a duration from the node's radio
  and the transfer estimate. An existing radio2 configuration is reported and
  left untouched.
- **Before/after image selection.** Choose the delta base explicitly (or force
  a full image), and import custom `.bin` builds on any platform. A custom
  image uses the board id the node itself reported.
- **Windows and macOS desktop builds**, alongside Linux; the release workflow
  attaches all three to the GitHub Release. TCP is a first-class transport on
  every platform, including file import/export on desktop.
- **App icon.** A repeater-and-update-loop launcher icon (generated from
  `app/assets/icon/icon.svg`) and a user-guide README with screenshots.

- **OP_INFO handshake.** The app now asks the node for its capabilities
  before arming: wire version, board target id, slot size, `max_literal`,
  and the feature bits (`supportsDelta`, `supportsApply`), plus the running
  firmware version and the running image's SHA-256 (`OtaNodeInfo`,
  `queryNodeInfo`). `UpdateFlow.stage` takes an optional `expectedTargetId`
  and refuses a definitive board mismatch before registering an arm; a node
  that does not answer is treated as unknown and proceeds as before (the
  SHA gate still protects the flash). `bench --scenario probe` prints the
  handshake too.
- **Board-mismatch fast fail.** `runUpdate` passes the selected environment's
  target id into `stage()`; a node reporting a different board id aborts
  staging with `UpdateFlowException` before any arm is registered.
- **Delta base by exact image hash.** The library now matches bases with
  `FirmwareLibrary.findBaseForSha()` against the handshake's running-image
  SHA-256 first, and only falls back to the `running=` version stamp. Two
  builds of one commit share a stamp and can still differ (the build date is
  embedded), which silently broke a delta and burned the whole transfer
  before the device's SHA gate rejected it.
- **The node's reported SHA-256 is the `.bin` hash.** It is taken over exactly
  the bytes an update wrote (length from the ESP image header, appended
  digest included) instead of over the whole erase-filled partition, so it
  is comparable with the app's own images (`ota status` reports the same
  hash).
- **RESPONSE padding is handled by CRC.** `PUSH_CODE_BINARY_RESPONSE` payloads
  arrive zero-padded to a 16-byte block; the parser now trims by trying frame
  CRCs instead of assuming the frame ends at the last non-zero byte (which
  broke reports whose CRC ends in `0x00`, and every report larger than one
  block, including `OP_INFO_REPORT`).

### Changed

- **The firmware picker lists versions, not boards.** The board dropdown is
  gone; a version row, its save state and its trash icon are the whole
  interaction. Releases with no image for the board the node reported are
  hidden. In an update, tapping a version downloads only the image this node
  needs (just-in-time, from disk when already saved); the cloud button
  downloads every board's image of the version. Offline mode shows just the
  versions saved on the device in the GitHub tab — there is no separate
  Offline tab. Imported `.bin` files are unchanged.

- **Connect auto-advances.** Tapping a BLE companion or the TCP Connect
  button lands the operator on the repeater step without a second tap; the
  connected state offers one forward action (Continue) for the
  back-navigation case. The connected screen shows only the connection
  card — the transport form is hidden while connected.
- **Sign-in auto-advances.** A successful node check lands the operator on
  the firmware step by itself — no "Next" tap. The password card hides once
  signed in; the node facts stay visible and the step bar is the way back.
- **Review screen follows the wizard: one action at a time.** The
  **Choose base** button is on the left and **Change image** on the right.
  The **Work offline** switch is gone — offline mode is decided before this
  step (the firmware screen).

### Changed

- **The transfer estimate is op-round-trip based, not airtime.** The node is
  deaf while each literal op commits to flash (~1.4–1.5 s/op measured);
  the old airtime model was ~15x optimistic. The radio screens, the review
  step and the tempradio duration suggestion all use the new model, and the
  transfer screen now shows **time left at the measured rate** plus KB/s once
  a few ops have landed.

### Fixed

- **A mid-transfer transport failure no longer leaves a dead Cancel button.**
  The companion's binary-request timeout (5 s) crashed the transfer while
  the UI stayed in `transferring`; the update now unwinds to `failed` with a
  Back action. A failure *before* the transfer (a refused arm, a rejected
  radio move) now unwinds the same way instead of sitting on `staging` with a
  Cancel button that can never finish.
- **The transfer estimate now counts the ops the app actually sends.** The
  estimate divided the image by the on-air literal size (173 bytes) while a
  stock companion carries 132, so every estimate and every suggested
  `tempradio` duration was about a third short. Estimates and the duration
  suggestion are correspondingly longer.
- **Progress can no longer read more than 100%.** The node advances its
  `next_expected` watermark for `OP_END` too, which is one more than the op
  count the app displays; the reported figure is clamped.
- **Rolling back no longer claims the update was verified.** The verify step
  said "Update verified — its image matches the one that was sent" after a
  rollback, which only proves the node answered admin CLI again. It now
  reports the rollback, and the rollback action is unavailable while an
  apply/verify is still deciding (it would race the in-flight reboot).
- **Changing the repeater drops the old node's delta plan.** The review step
  could show (and the transfer could use) a delta computed against the
  previous repeater's running image; the plan is now invalidated with the
  rest of the node facts, and the op stream is always rebuilt from the base
  the update will actually use.

- **An imported or downloaded image now appears immediately.** The library
  updated its in-memory list without notifying listeners, so newly imported
  files did not show until the app was restarted; the screen rebuilds
  immediately now (pinned by a widget test).

### Removed

- **The field pack.** The library screen's `.zip` import/export is gone. Move
  images between devices by importing the `.bin` files directly (one at a
  time, on any platform, including desktop) or by re-downloading the version.

### Changed

- **The OTA wire contract: ops now ride ordinary REQ/RESPONSE datagrams.**
  Each op is sent as `CMD_SEND_BINARY_REQ`
  (`[pub_key][REQ_TYPE_OTA][frame_len][op frame]`) to the companion, which
  encrypts it as an ordinary direct REQ to the node; the
  OP_REPORT comes back inside the RESPONSE as `PUSH_CODE_BINARY_RESPONSE`.
  Intermediate nodes forward them without any custom firmware. **Requires the
  matching fork firmware** — nodes running the earlier raw-custom build are
  not compatible with this app version.
- `OP_ASK` carries no body; the report rides the standard REQ reply routing.
  The transfer engine requires a `contact` (binary requests are addressed to
  the companion's saved record for it).
- Literal chunk size for stock companions is 132 bytes (the frame limit less
  the binary-request envelope and the `frame_len` byte).
- `parseBinaryResponse` is now shared between transfer/resume code and the
  new handshake; the two `PUSH_CODE_BINARY_RESPONSE` layouts seen in the
  field (old tag-first, current pubkey-then-tag) both parse.
- The bench's `--path` flag now pushes the path into the companion's contact
  record (like `change_path`), since binary requests carry no per-packet path.
  The app's DIRECT-path override does the same when an update starts.
- `bench/bin/probe.dart`, `probe2.dart`, `slot_probe.dart`,
  `reboot-during-stage.dart` updated to the binary-request transport.

### Added

- Initial pre-bench release. BLE (NUS) and TCP transports to a stock companion.
- `RadioLink.sendBinaryRequest` and `setContactPath` (TCP/BLE/fake): binary
  requests with contact-path override (binary framing and the companion's
  `CMD_ADD_UPDATE_CONTACT` record write).
- Linux desktop build (testing target): the full OTA flow over TCP against a
  WiFi/Ethernet companion or simulator; BLE stays mobile-only (library
  browse/delete/import work everywhere), no foreground service on desktop.
- Repeater picker: companion contacts (repeater-filtered, manual pubkey
  entry), admin login, `ota status` probe.
- Firmware sources: fork GitHub releases (stable + dev track) with optional
  SHA256SUMS verification; offline library of downloaded versions.
- Delta updates by default (rolling-hash matcher, full-position index);
  full-image fallback; airtime estimate at the companion's radio config.
- Windowed op-stream transfer with OP_ASK/OP_REPORT recovery; cancel =
  `ota abort` (safe).
- `ota apply` commit step, post-reboot re-login and `version` verification,
  and one-button `ota rollback`.
- CI (analyze/test/coverage/APKs) and signed release pipeline
  (see `docs/releasing.md`).
