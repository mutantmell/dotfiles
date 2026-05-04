# Replace nerdctl inspect with containerd API + CNI state — COMPLETE

Implemented: `deployd-exec inspect` now uses `ctr` + CNI host-local state scan
instead of `nerdctl inspect`. VM test added for the inspect flow.

Findings and the recommended next step (containerd gRPC client in Rust) are
documented in `deployd-integration.md` under "Architecture Change: Containerd
gRPC Consolidation."
