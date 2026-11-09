# Plane Fork Build Results

Results of the offline archive builds (`fork/build/build.sh`, images `localhost/plane-fork-*:v1.4.3-live.<N>`). Build 1 below
is the earlier v1.4.2-live.1 build. These are history and the offline fallback only: since PLN-109 the fork images are built
in CI (`.github/workflows/fork-images.yml`, `ghcr.io/austinnorgaard/plane-fork-*:sha-<sha>`) and deployed with
`fork/deploy/update.sh` (see `fork/deploy/RUNBOOK.md`, "Updates"). The fork is based on upstream v1.4.3 and keeps no test
suites (removed on 2026-11-08); changes are checked with tsc, oxlint, oxfmt, ruff, py_compile and shellcheck.

## Builds

### Build 1 - 2026-09-30 04:38:30 UTC

- SHA: 6983450e93af4c057572dcdb7e4f1581a71bc171
- Output: plane-fork-live.1.tar, sha256 d741e71eab23edacaa9746edf6132ff7ac2f6528ce15ace784a0925bd1a3ad48 (plane-fork-live.1.sha256)
- Tags: localhost/plane-fork-api:v1.4.2-live.1, localhost/plane-fork-live:v1.4.2-live.1, localhost/plane-fork-web:v1.4.2-live.1
- web build: 137 s wall, peak RAM used 2650 MB (+1785 MB over idle), lowest available 13192 MB
- live build: 200 s wall, peak RAM used 1818 MB (+842 MB over idle), lowest available 14026 MB
- api build: 2 s wall, peak RAM used 1209 MB (+0 MB over idle), lowest available 14865 MB
- Prune (plane-fork-build=6983450e93af4c057572dcdb7e4f1581a71bc171, dangling only): 0 image(s) removed
