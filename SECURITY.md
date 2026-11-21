# Security

## Threat model

MeshCoreRepeaterManager moves firmware images over LoRa to a repeater, from a phone that
already has a trusted relationship with the companion it is connected to.
The design goal: **an attacker who can transmit on the same radio can never
make the node boot a different image**, and **a broken image can never stay
booted**. Availability attacks (jamming) are out of scope — that is physics,
not policy.

Layered controls, in order:

1. **Arming requires an operator.** A repeater-side `ota stage <size> <sha256>
   <ver>` registers a pending arm `{size, sha256, token}` with a 120-second
   single-use TTL. Only an authenticated admin session (the same ECDH-encrypted
   TXT_MSG path as every other repeater command) can do this.
2. **OP_START is bound to the arm.** It carries `size:u32 sha256[32]
   target:u32 token:u32`; the node accepts it only while an unexpired pending
   arm exists whose token AND `{size, sha256}` match — and the arm is consumed
   on acceptance. An overheard OP_START arms nothing but the operator-approved
   image. Anything else is dropped before `esp_ota_begin()` runs, so a flood of
   forged packets cannot wear out the inactive slot.
3. **`target:u32 = sha256(pio_env)[0..3]`** binds the stream to the board this
   image was built for. Flashing a different board's image is refused at
   OP_START with `err=1`.
4. **SHA-256 gate at `OP_END`.** The staged slot is hashed; mismatch → staged
   slot scrapped, `state=error`, `err=4`. This is the only integrity decision
   in the design; the op stream itself is trustless once armed.
5. **The diff oracle is admin-only and read-only.** `OP_BLOCK_HASH` (0x09)
   and `OP_BLOCK_FIND` (0x0B) ride the same admin-gated `REQ_TYPE_OTA` path as
   every other op. They answer SHA-256 hashes of bounded ranges and the offsets
   where 64-bit rolling fingerprints occur, are answered in every session
   state, and never write flash or change the session. They leak nothing
   beyond the public firmware's contents and version; brute-forcing bytes from
   a range hash is infeasible, and a 64-bit fingerprint collision only costs an
   extra literal. A stale or wrong diff can therefore waste airtime but cannot
   boot a wrong image — the SHA gate (4) still decides. Compressed literals
   follow the same rule: a truncated or corrupt DEFLATE stream is rejected
   with `err=9` before the SHA gate, never installed partially.
6. **Commit requires an admin.** `ota apply` refuses unless staging is
   `state=ready`, then flips the boot partition and reboots.
7. **Boot health check + auto rollback.** The freshly applied image runs a
   boot health check (LoRa init + one zero-hop packet TX). Failure flips the
   boot partition back to the previous slot and reboots — with no app at all.
   The app *additionally* re-logs in and checks `version` after the reboot.

What an on-air attacker **can** do: observe that an update is happening
(public release metadata: board, size, SHA-256), re-deliver the genuine
release to a node whose operator armed it (zero gain), jam or corrupt the
transfer (denial of availability; recoverable with `ota abort` + re-stage),
and fuzz the op interpreter (bounded — every frame is CRC-checked and size-
capped; errors reach `state=error`, never panic).

What they **cannot** do: install a modified image (4), boot it without an
admin (5) and a passing SHA gate (4), target the wrong board (3), arm the
node at all (1), or learn anything secret in transit — firmware images are
public releases, and the arm token never travels in the clear *inside the
authenticated CLI channel except inside `ota stage`'s encrypted reply* (the
OP_START frame itself is cleartext by design; its safety is (2), not secrecy).

Deliberately **not** encrypted: the LoRa op stream. Wire confidentiality of
public firmware buys nothing, and E2E encryption per hop would add cost and
code with no new guarantee at the arm/SHA/apply gates.

## Secrets the app holds

- **Repeater admin password** — per session only, in memory, never logged,
  never persisted (no `flutter_secure_storage` use). Closing the app forgets
  it. A blank password is a legitimate login when the companion's key is
  already an admin in the node's ACL; the app sends the stock blank-login
  request and the node decides. Anyone with the unlocked phone during a
  session has the same admin session as the user — same as any logged-in
  repeater app.
- **Companion connection** — BLE pairing is handled by the OS; the app never
  sees or stores pairing keys.

## Management data

Repeater management adds three kinds of local data, all on the device only:

- **Settings and status cache** (`repeaters/<id>/cache.json`) holds last-known
  values with their fetch time and source, plus bounded chart samples of
  non-secret counters (battery, traffic, airtime, uptime, errors and neighbour
  counts). It never holds the admin password, guest password, private keys,
  fleet PSK or MQTT credentials. MQTT secrets are write-only and excluded from
  reads, cache and diagnostics.
- **Management audit log** (`management_audit.json`) records writes only: the
  command family, the command text with credential values redacted, the reply
  classification and the outcome. A lost reply is recorded as unknown, never
  as success. The most recent 1000 entries are kept and can be exported.
- **Capability probes** are strictly read-only. An unanswered probe means "not
  confirmed", not "unsupported", and nothing is inferred from a single reply
  without the full probe set agreeing.
- **Management writes** always carry an explicit outcome. A reply that never
  arrived is recorded and shown as unknown, never as success; settings changes
  are re-read before the app claims they landed. The access-list screen asks a
  second time before lowering or removing the companion's own entry, and the
  raw command line refuses serial-only or destructive commands such as
  `get prv.key` and `erase` outright. Filter rule deletion asks first, and the
  editor's dry run is advisory: the repeater decides every packet.
- **Joining the update hotspot is narrow and reversible by hand.** The app attempts a single network connect through the desktop OS tooling only, never edits saved network configuration, and falls back to an explicit manual-join screen if the OS refuses. Mobile platforms always use the manual path.
- **WiFi update uses plain HTTP on a trusted LAN or an open hotspot.** The app
  warns before arming the page, never sends the admin password over HTTP, and
  treats a lost upload reply as unknown until a re-login and version read
  confirm the reboot. Device-side HTTP authentication is out of scope, so this
  limitation is disclosed in the UI rather than fixed in firmware.
- **Secrets are remembered only by explicit opt-in.** The fleet PSK and MQTT username, password and token for each broker may be stored in platform secure storage, one field at a time. WiFi and admin/guest passwords are never eligible. Where the platform has no secure storage the opt-in is disabled and the value stays in memory. No secret is written to the cache, audit log, exports or diagnostics.
- **Route changes are explicit and validated.** The routing sheet only accepts the firmware's path grammar and reports a failed companion write instead of assuming the new path landed. A failed companion write is reported instead of assuming the path changed.
- **Long-running work is visible and bounded.** One ref-counted foreground
guard owns transfers, apply/rollback, scheduled jobs, a two-minute ACK
window and WiFi uploads. A refused foreground start aborts the operation
before it sends or flashes. Fleet results and the audit log are local,
bounded, and offer a copy action; both warn before old records roll off.
- **Fleet scripts execute with the repeater's own privileges.** The composer
  and the bulk-settings screen show the exact text and ask before sending;
  received group text is never executed by the app, only key-prefixed ACKs are
  parsed. Bulk settings are restricted to a curated subset of deterministic,
  low-blast-radius keys with no passwords, keys or radio presets. The PSK is entered
  per session (or explicitly opted into secure storage in a later milestone),
  is never written to the cache, and is not included in logs or exports. A
  missing reply is shown as No reply, never as success.

The settings file, audit log and repeater index are schema-versioned. A file
from a newer schema is reported, not overwritten, and migrations keep the
offline flag, firmware images and saved updates intact.

## What the app never does

- No telemetry, no analytics, no crash reporting, no network access except
  the firmware catalog/download endpoints (`api.github.com`,
  `objects.githubusercontent.com` for the fork's releases). The **offline**
  switch disables even those: the app never contacts GitHub while it is on.
- No persistent copy of uploaded images beyond the local **library** (explicit
  user action), which holds only public release images and their SHA-256.
  The only other app-owned state is `ota_settings.json` (the offline flag) and
  `ota_resume.bin` — a record of an interrupted update. It contains the target
  repeater's public key and name, the firmware's SHA-256 and version, the radio
  choice, and the exact op frames already generated. It has **no admin
  password** and no private key material. Resuming always asks for the admin
  password again. Delete it any time with **Cancel resume** on the recovery
  screen; it changes nothing on the repeater until an update is resumed.
- No store listing dependency — releases are GitHub Releases (signed Android
  APKs and unsigned desktop bundles).

## Reporting

This is a personal project for a self-hosted mesh fork. Report issues by
opening a private security advisory on
[jhuebert/MeshCoreRepeaterManager](https://github.com/jhuebert/MeshCoreRepeaterManager/security/advisories/new)
(or on the fork, for firmware-side issues:
[jhuebert/MeshCore](https://github.com/jhuebert/MeshCore/security/advisories/new)).
Administration session hygiene is your responsibility: change the repeater
admin password if a session may have leaked, exactly as you would for any
remote administration.
