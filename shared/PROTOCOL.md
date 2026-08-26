# DesCon peer protocol

DesCon uses peer-to-peer LAN communication. There is no cloud service and no
separate daemon: the macOS menu-bar app and Windows tray app own their listeners.

Managed profile activation is a two-phase transaction:

- The macOS client always initiates `Mac → Windows`.
- The Windows client always initiates `Windows → Mac`.
- `managedTarget` exists only in the transaction payload so the receiving peer
  can reject a command sent in the wrong direction; it is not user-configurable.

1. `prepare` carries the complete profile and a unique transaction ID.
2. The peer authenticates the request and validates that the managed profile
    targets its platform.
3. The current host chooses a safe fallback primary and sends DDC while its link
   is still available.
4. `commit` tells the destination to apply its pending topology after the display
   reconfiguration event.

Monitor actions use a per-monitor network identity. A user-defined Pairing ID
is normalized case-insensitively and sent as `PAIR:<id>`; when it is empty, the
clients fall back to the monitor's EDID-derived shared identity. Display numbers
are local UI labels and are never used for cross-device matching.

External profiles deliberately skip the peer phases. They apply the initiating
host's safe pre-switch topology, send DDC, then report `sent-unverified`.

Messages are newline-delimited UTF-8 JSON over TCP. Discovery uses a LAN multicast
announcement; commands are never broadcast. Production messages carry an HMAC
SHA-256 signature over `version|id|timestamp|nonce|type|payload` and peers reject
timestamps outside 30 seconds or repeated nonces.

Persistent profile documents follow [profile.schema.json](profile.schema.json).
The transaction payload carries only the selected profile actions, replacing
host-local monitor IDs with the canonical EDID-based `sharedID` used by both
clients.
