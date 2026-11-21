# Attribution

This repository reuses code from [MeshChameleon](https://github.com/jhuebert/MeshChameleon)
(<https://github.com/jhuebert/MeshChameleon>), also MIT-licensed by the same
author, via `git subtree` (full history retained):

- `packages/mesh_protocol/` — on-air packet codec, crypto, identity,
  companion-frame codecs, constants. The MeshChameleon port itself reuses
  MIT-licensed code from `meshcore-open` (zjs81/meshcore-open) and
  `openhop_core` (openhop-dev/openhop_core); see MeshChameleon's
  `ATTRIBUTION.md` for that upstream list, which applies to this project too.
- `packages/device_link/` — the `RadioLink` transport SPI, the TCP companion
  client, and the fake device link used by tests.
- `packages/test_support/` — shared test plumbing (framed TCP client, stream
  queue, fake scheduler).

MeshChameleon's own MIT notice and upstream attributions are retained in
`packages/mesh_protocol/` and `packages/device_link/` via history.

MeshCoreRepeaterManager's new code (the `companion_client`, `ota_core`,
`repeater_core` and `wifi_ota_core` packages, and the `app/` Flutter
application) is original to this repository, MIT, same author.

MeshCore is a project of meshcore-dev (<https://github.com/meshcore-dev/MeshCore>),
MIT-licensed; OTA firmware images consumed by this app are built by
<https://github.com/jhuebert/MeshCore>, also MIT.
