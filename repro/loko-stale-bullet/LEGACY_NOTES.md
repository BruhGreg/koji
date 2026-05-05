# Legacy Notes

Untagged narrative doc — no `covers:` frontmatter. Has NOT been
mentioned in any active session body and has been in LOKO for ≥ 2
wraps. Demonstrates Fix B's deterministic-remove path for the
exempt/untagged-default-keep escape.

Under v0.4.8 this doc was kept indefinitely (default-keep bias for
untagged manually-pinned docs). Under Fix B this doc is auto-removed
because `presence=established` AND `mentioned=no` overrides the
default-keep bias.
