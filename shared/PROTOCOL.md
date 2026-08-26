# DesCon peer protocol

DesCon uses peer-to-peer LAN communication. There is no cloud service and no
separate daemon: the macOS menu-bar app and Windows tray app own their listeners.

Managed profile activation is a two-phase transaction:

1. `prepare` carries the complete profile and a unique transaction ID.
2. The peer authenticates the request and validates that the managed profile
   targets its platform.
3. The current host chooses a safe fallback primary and sends DDC while its link
   is still available.
4. `commit` tells the destination to apply its pending topology after the display
   reconfiguration event.

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
