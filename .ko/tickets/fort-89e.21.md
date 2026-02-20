---
id: fort-89e.21
status: closed
deps: [fort-89e.19]
links: []
created: 2025-12-30T22:06:45.735240703Z
type: task
priority: 3
parent: fort-89e
---
# Large file transfer protocol

Design and implement secure large file transfer over control plane.

Primary use case: Media ingestion - 'please put this 100GB file on the NAS'

The agent protocol is request/response JSON, not suitable for large transfers.
Need a separate protocol built on top of the agent:

Options to explore:
1. Agent returns a ticket (nonce + port + one-time TLS cert), separate listener accepts upload
2. Agent returns a signed URL for direct upload to destination
3. Agent coordinates rsync/rclone with pre-shared credentials

Considerations:
- Must be encrypted in transit
- Must handle connection failures gracefully
- Must not exhaust file descriptors with unclaimed transfers
- Timeout/cleanup for abandoned transfers

This is a design + implementation ticket - flesh out the approach before building.

## Design

Deferred until core control plane is working.
Start with design doc exploring the options above.
May want to prototype with a simple use case before full implementation.

## Acceptance Criteria

- Design document with chosen approach
- Working implementation for file upload to NAS
- Handles failures gracefully (timeouts, cleanup)
- No resource leaks


