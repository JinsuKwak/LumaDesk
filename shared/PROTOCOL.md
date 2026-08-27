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

`self` (`This Device`) profiles carry two explicit anchors. `selfPrimaryMonitorID`
becomes Primary on the computer which launches the profile and its other assigned
monitors become Extended. `peerPrimaryMonitorID` remains the peer's recoverable
Primary while the peer hands off/disables the other assigned paths. This avoids an
invalid zero-display Windows topology and also keeps a Mac mini recoverable when it
has no built-in display. A later profile which assigns Primary/Extended restores
those paths after DDC with bounded retries; there is no steady-state topology poll.

Monitor actions use a per-monitor network identity. A user-defined Pairing ID
is normalized case-insensitively and sent as `PAIR:<id>`; when it is empty, the
clients fall back to the monitor's EDID-derived shared identity. Display numbers
are local UI labels and are never used for cross-device matching. Local profile
assignments also prefer this Pairing ID so input and topology behaviors survive
display-number and OS-local identifier changes.

External profiles deliberately skip the peer phases. They apply the initiating
host's safe pre-switch topology, send DDC, then report `sent-unverified`.

Restore Layout profiles are never serialized onto this protocol. They store a
host-local monitor set and Primary, then restore the local Primary/Extended
topology without DDC input commands or peer discovery/transactions.

Managed profiles may set `restorePeerLayout`. When true (and for older payloads
where the field is absent), the receiving peer reapplies its requested display
topology after the physical inputs arrive. When false, the peer acknowledges the
transaction without changing its local display topology.

Messages are newline-delimited UTF-8 JSON over TCP. Discovery uses a short LAN
multicast probe at launch, on demand, or after the user requests Rescan. A peer
answers once and the endpoint is cached for direct commands. As soon as either
side receives a multicast announcement it sends an authenticated direct TCP
`hello`; the receiver registers the caller too, so one-way multicast delivery
still produces a symmetric peer connection. Failed hellos may be retried by the
bounded handshake retry or the next manual Rescan. There is no periodic
background announcement. Commands are never broadcast. Production messages carry an HMAC
SHA-256 signature over `version|id|timestamp|nonce|type|payload` and peers reject
timestamps outside 30 seconds or repeated nonces.

Persistent profile documents follow [profile.schema.json](profile.schema.json).
The transaction payload carries only the selected profile actions, replacing
host-local monitor IDs with the canonical EDID-based `sharedID` used by both
clients.
