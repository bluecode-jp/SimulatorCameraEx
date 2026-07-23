# SCMF — Simulator Camera Message Format

> ⚠️ **Historical (v0.2.x).** SCMF was the wire format between the TCP
> server and the `SimulatorCameraClient` iOS SDK, both removed in v1.0.0.
> Frames now travel through macOS CoreMediaIO via `CMIOExtensionStream`,
> so there is no wire protocol and no SDK to link. Kept for reference.

`v1` · little-endian on the wire · framed over TCP.

## Wire layout

```
+--------+---------------+------------------+--------+---------+------------------+
| magic  | payloadLength | timestamp        | width  | height  | jpegData         |
| 4 B    | 4 B uint32 LE | 8 B Float64 LE   | 4 B LE | 4 B LE  | payloadLength-16 |
+--------+---------------+------------------+--------+---------+------------------+
```

| Field | Type | Notes |
| --- | --- | --- |
| `magic` | 4 bytes, ASCII | `0x53 0x43 0x4D 0x46` — `"SCMF"` |
| `payloadLength` | uint32 LE | Size of `timestamp + width + height + jpegData` = `16 + jpegData.count` |
| `timestamp` | Float64 LE | Seconds since a server-chosen epoch (monotonic) |
| `width` | uint32 LE | Frame width in pixels |
| `height` | uint32 LE | Frame height in pixels |
| `jpegData` | bytes | Baseline or progressive JPEG, any color space |

Integers MUST be little-endian. Decoders should use unaligned loads — the ARM64 Simulator is strict about alignment.

## Framing rules

1. A single TCP connection is a stream of consecutive SCMF frames.
2. The server MAY send any number of frames. The client MUST drain all complete frames on every read.
3. If the client reads a frame whose `magic` is not `"SCMF"`, it MUST close the connection — the stream is corrupt.
4. If a TCP read yields fewer than `8 + payloadLength` bytes, the client MUST buffer and wait for more data.

## Transport

- Default endpoint: `127.0.0.1:9876`
- Localhost-only by default. Servers that expose a LAN port MUST log a warning.
- No TLS in v1. All frames transit loopback; add TLS in v2 for remote use.

## Versioning

The protocol is versioned by the 4th byte of `magic`. Current `SCMF` = v1. Future `SCMG`/`SCMH` reserved for HEVC / multi-track.

## Reference encoder (Swift)

The reference implementation lived in `Sources/SimulatorCameraClient/SCMFDecoder.swift`
(`SCMFCodec.encode(_:)`), deleted in v1.0.0. To read it, check out the last
commit before removal:

```bash
git show 3bbc6f6^:Sources/SimulatorCameraClient/SCMFDecoder.swift
```
