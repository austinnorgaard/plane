<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# LU-02 spike: build and test environments in a WSL podman distro

Ticket: PLN-2 (LU-02). Scope: stock Plane v1.4.2 only, no feature code.
Run date: 2026-09-29, on a Windows development PC using a WSL podman distro. No production system was touched.

## Verdict: GO

The go/no-go criterion (cache mounts) passes. Every image builds, boots or
verifies, the API and node test suites are green on unmodified v1.4.2, and the
web bundle matches the upstream image. Two ticket assumptions did not hold as
written (the live server needs a Redis to boot, and the MinIO image can no
longer be pulled) and two tooling traps were found and fixed (pnpm 11 store
location, workspace packages must be built before some checks). See
"Deviations from the ticket, and findings". None is a blocker.

| Check                                                                        | Result                                                                         |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| podman handles `# syntax=docker/dockerfile:1.7` and `RUN --mount=type=cache` | PASS (cache hit on second build)                                               |
| Stock web image builds with no build args, no OOM                            | PASS, 209 s, peak 2913 MB                                                      |
| Web bundle parity with makeplane/plane-frontend:v1.4.2                       | PASS (same file count, same VITE defaults)                                     |
| Stock live image builds and `/live/health` returns 200                       | PASS, but only with a Redis sidecar (see D1)                                   |
| Backend overlay: `manage.py check`, pip freeze equal to base                 | PASS                                                                           |
| `podman save -m` / `podman load` round trip                                  | PASS, image IDs identical                                                      |
| API tests: pod, no published ports, pytest baseline                          | PASS, 514 passed, 0 failed (no minio, see D2)                                  |
| Node tests: install, vitest, tsc, oxlint baseline                            | PASS after building workspace packages first (see D3)                          |
| No visible windows                                                           | PASS, WindowsTerminal count 2 before and after, OpenConsole 0 before and after |

## Environment

- Host: Windows 11, 20 logical CPUs, shared with other workloads. When the spike started the host was already at about 50% CPU.
- WSL distro `<distro>` (Fedora 40 container image as a distro), always driven as `wsl.exe -d <distro> -u root -- <cmd>`. WSL2 VM: 15946 MB RAM, 20 CPUs, 4096 MB swap, no `.wslconfig`. Ample free disk.
- podman 5.3.1, buildah 1.38.0, crun, netavark/aardvark 1.13.1, rootful, cgroup v2, overlay storage. `podman compose version`: no provider (nothing installed, nothing needed).
- Preflight: `podman images`, `ps -a`, `pod ls`, `volume ls` were all empty before the first pull.
- Builds ran with `--cpu-period=100000 --cpu-quota=800000` (8 of 20 logical CPUs) and node/pytest containers with `--cpus=8`, to keep the shared host responsive. Host CPU was not sampled during the builds, so the wall times below are for an 8-CPU cap on a busy host, not for an idle machine.

## Measurements

### 1. Sync

| Method                                                                                         | Time                                                       |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `git archive live-updates/v1.4.2 \| tar -x` into `/root/plane-build/spike` (5257 files, 70 MB) | 0.7 s                                                      |
| `fork/test/sync.ps1`, cold Windows file cache                                                  | 44.4 s                                                     |
| `fork/test/sync.ps1`, warm (every later run)                                                   | 2.3 s to 3.9 s (clean 0.3-0.7, stream 1.2-3.1, repair 0.4) |

Found: a plain `tar.exe` copy of a Windows checkout loses two things. The one tracked symlink (`packages/i18n/locales -> src/locales`) becomes an 11-byte text file, and every exec bit is gone (14 tracked 100755 files, including `apps/api/bin/*.sh` and `setup.sh`). `sync.ps1` repairs both from `git ls-files -s` after the stream. The PowerShell 5.1 pipeline is text-only and corrupts a binary pipe, so the script streams through `cmd.exe /c "tar.exe ... | wsl.exe ... tar -x"`.

### 2. Cache-mount probe (`fork/test/cache-probe/Containerfile`)

- The `# syntax=docker/dockerfile:1.7` line is accepted (buildah treats it as a comment; no BuildKit involved).
- Build 1 (`--no-cache`) printed `CACHE-MISS: writing marker`, build 2 (`--no-cache`) printed `CACHE-HIT: <marker>`. `RUN --mount=type=cache,id=...` persists across builds and is not baked into the image.
- The cache lives in `/var/tmp/buildah-cache-0/<hash of id>` on the distro disk (for example the pnpm one is 1.1 GB), outside any image layer. The pnpm cache mount (`id=pnpm-store`) is the same mechanism and is what makes the incremental web rebuild faster.

### 3. Web image (`apps/web/Dockerfile.web`, no build args)

| Metric                                                                           | Value                                                                           |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Wall time, cold (pulls, corepack, pnpm fetch, turbo build)                       | 209 s                                                                           |
| Wall time, one-line change to `apps/web/app/root.tsx`, warm layer and pnpm cache | 149 s (13 steps cached, `pnpm fetch`, install and the whole turbo build re-run) |
| Peak RAM, `free -m` every 5 s (cold)                                             | 2913 MB used (571 MB idle baseline, +2342 MB)                                   |
| Min MemAvailable, 1 s sampling (cold)                                            | 12778 MB of 15946 MB                                                            |
| Peak swap                                                                        | 0 MB                                                                            |
| Peak RAM, incremental rebuild                                                    | 3245 MB used                                                                    |
| OOM                                                                              | none                                                                            |
| Image size                                                                       | 97 MB (upstream image: 97.2 MB)                                                 |
| Boot check                                                                       | nginx 1.31.6 answers `GET /` with 200 and the SPA `index.html`                  |

`build-branch.yml` passes no build args for web, so the Dockerfile defaults are what upstream ships. Confirmed in the bundle (see parity below).

Parity against `docker.io/makeplane/plane-frontend:v1.4.2` (`/usr/share/nginx/html` copied out of both):

|              | ours       | upstream   |
| ------------ | ---------- | ---------- |
| files / dirs | 1101 / 5   | 1101 / 5   |
| .js / .css   | 916 / 3    | 916 / 3    |
| total bytes  | 31,532,934 | 31,532,936 |

- 1072 files share a name; 1071 are byte-identical. The one difference is `index.html`, which is identical after normalising the content hash in chunk file names.
- 29 chunk files exist under different hashed names on each side. 28 of the 29 pairs have identical byte size (the 29th differs by 2 bytes, a hash-length change inside a filename reference). Chunk hashes differ between the two builds even though sizes match; the cause was not investigated, so treat hashed file names as unstable and compare by count and size.
- Every bundle carries the same embedded config: `VITE_API_BASE_URL`, `VITE_WEB_BASE_URL`, `VITE_ADMIN_BASE_URL`, `VITE_LIVE_BASE_URL`, `VITE_SPACE_BASE_URL` are all empty strings; `VITE_ADMIN_BASE_PATH="/god-mode"`, `VITE_LIVE_BASE_PATH="/live"`, `VITE_SPACE_BASE_PATH="/spaces"`. `/live`, `/god-mode` and `/spaces` each appear in 6 JS files on both sides.
- The set of `http(s)://host` strings in the bundles is identical (57 hosts on each side). The only localhost is `http://localhost` inside library fallback code, present in both. No absolute base URL of ours is baked in.

Stock VITE args confirmed: build with no args and the result matches upstream.

### 4. Live image (`apps/live/Dockerfile.live`)

| Metric                                                                                                     | Value                                                                               |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Wall time, cold                                                                                            | 245 s                                                                               |
| Peak RAM (5 s sampling)                                                                                    | 1912 MB used (623 MB baseline, +1289 MB)                                            |
| Min MemAvailable                                                                                           | 13954 MB                                                                            |
| Image size                                                                                                 | 1.15 GB (the runner stage copies all of `/app/node_modules` and `packages/`)        |
| Boot with `API_BASE_URL=http://127.0.0.1:9`, dummy `LIVE_SERVER_SECRET_KEY`, **no Redis**                  | exits 1: `Redis client not initialized` (see D1)                                    |
| Boot with the same env plus `REDIS_URL=redis://127.0.0.1:6379` and a valkey 7.2.11 sidecar in the same pod | `GET /live/health` returns `200 {"status":"OK",...}`; container memory about 248 MB |

### 5. Backend overlay (`fork/docker/Dockerfile.fork-api`)

| Metric                                                                                | Value                                                                            |
| ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Build time                                                                            | 4 s (one COPY layer)                                                             |
| Image size                                                                            | 331 MB (base `makeplane/plane-backend:v1.4.2` is 326 MB; the layer adds 4.57 MB) |
| `python manage.py check` (dummy `SECRET_KEY`, `DATABASE_URL`, `REDIS_URL`, `WEB_URL`) | "System check identified no issues (0 silenced)", same as the base image         |
| `pip freeze` overlay vs base                                                          | identical, 110 packages                                                          |
| `.py` files under `/code/plane`                                                       | 649, same as `apps/api/plane`                                                    |

### 6. Transfer format (`podman save -m --format docker-archive`, web + live + api)

| Metric                                | Value                                        |
| ------------------------------------- | -------------------------------------------- |
| Save time                             | 43.7 s                                       |
| Tar size                              | 1,568,002,560 bytes (1.46 GiB)               |
| `gzip -6` of the tar (single thread)  | 447,705,554 bytes (427 MB), 54.9 s           |
| Load time after removing the 3 images | 22.1 s                                       |
| Result                                | all 3 image IDs identical to before the save |

The api image carries its full 326 MB base in the archive; docker-archive does not dedupe against a base the target already holds.

### 7. API tests (`fork/test/api-tests.sh`)

- Pod `plane-apitest`: postgres 15.7-alpine, valkey 7.2.11-alpine, rabbitmq 3.13.6-management-alpine, all on tmpfs, no `-p` anywhere. minio is optional and off (D2).
- Runner: `docker.io/makeplane/plane-backend:v1.4.2` with `apps/api` mounted at `/code`, `pip install -r requirements/test.txt`, `DATABASE_URL` and `REDIS_URL` pointing at `127.0.0.1` (pod-shared network).
- pip: 15 wheels downloaded, 0 sdists, 0 lines matching `Building wheel|Running setup.py|Preparing metadata (pyproject.toml)`. `coverage-7.2.7` resolves to `cp312-musllinux_1_1_x86_64`. Nothing compiles. `pytest-mock 3.11.1` imports (the pages tests need it).
- Baseline, unmodified v1.4.2, `pytest plane/tests/unit plane/tests/contract`:
  - **514 passed, 0 failed, 0 errors, 0 skipped, 92 warnings**
  - pytest time 149.3 s; whole script 186 s (pod boot, pip install, tests)
  - peak RAM 1122 MB used (674 MB baseline, +448 MB)
  - failing test ids: none
  - `plane/tests/smoke` was not in the ticket's command and was not run.
- Side effect to know: `test.txt` pins `httpx==0.24.1`, so the runner uninstalls the image's `httpx 0.28.1` on every run. Same as upstream's `docker-compose-test.yml`; harmless, but the runner does not have the production httpx.

### 8. Node tests (`fork/test/node-tests.sh`)

`node:22-alpine` (node v22.23.3 at run time), corepack pnpm 11.3.0 (from `packageManager`), volume `plane-pnpm-store` at `/pnpm`, source bind-mounted at `/work`.

Clean run of `node-tests.sh all` from a tree with no `node_modules` and no `dist` (pnpm store already populated): 125 s wall, peak RAM 1981 MB used (640 MB baseline, +1341 MB).

| Step       | Command                                                   | Result                                           | Wall                                                                                                                                     |
| ---------- | --------------------------------------------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| install    | `pnpm install --frozen-lockfile`                          | OK, 1457 packages, pnpm 11.3.0                   | 22 s with a warm store and no node_modules; 23 to 24 s with an empty store (fast network); 4 to 5 s when node_modules is already current |
| build-libs | `pnpm turbo run build --filter=live^... --filter=web^...` | 12 tasks, all OK                                 | 37 s cold; 3-8 s when turbo has a cache                                                                                                  |
| live-test  | `pnpm --filter live test`                                 | **2 files, 32 tests passed** (11 + 21), 0 failed | 10 s                                                                                                                                     |
| live-types | `pnpm --filter live check:types`                          | 0 errors                                         | 7 s                                                                                                                                      |
| web-types  | `pnpm --filter web check:types`                           | 0 errors                                         | 44 s                                                                                                                                     |
| web-lint   | `pnpm --filter web check:lint`                            | 0 errors, 780 warnings (limit 11957), 1877 files | 4 s                                                                                                                                      |

Do workspace packages have to be built first? **Yes.**

- `@plane/editor` (and everything it needs) must be built before `pnpm --filter live test`. Without a build, `tests/lib/pdf/pdf-rendering.test.ts` fails to load: `Failed to resolve entry for package "@plane/editor"` (the package's `main` is `./dist/index.js`). `effect-utils.test.ts` still passes (11 tests) because it does not touch the editor. So the pages vitest suites, which import `@plane/editor`, need `build-libs` first.
- `pnpm --filter web check:types` needs web's own workspace dependencies built. With only the live dependencies built it fails with 527 TS errors (`Cannot find module '@plane/i18n'`, `@plane/shared-state`, `@plane/services`, and knock-on implicit-any errors). After building `web^...` it is clean. This is also why upstream CI runs `turbo run build --affected` before `check:types`.
- `check:lint` does not need a build.

## Deviations from the ticket, and findings (read these before LU-08)

D1. **Live does not boot without Redis.** The ticket's env (`API_BASE_URL`, `LIVE_SERVER_SECRET_KEY`) is not enough: startup calls the Redis manager and exits 1 with `Redis client not initialized`. Add `REDIS_URL` and a valkey container. `fork/test/live-smoke.sh` does this (pod with a valkey sidecar, nothing published) and was run against the built image: `HTTP 200`.

D2. **The MinIO image cannot be pulled.** `docker.io/minio/minio:latest`, `docker.io/minio/minio:RELEASE.2025-04-22T22-12-26Z` and `quay.io/minio/minio:latest` all answer "access denied / unauthorized". Upstream's `docker-compose.yml`, `docker-compose-test.yml` and the community CLI compose file still reference `minio/minio`, so a stock `docker compose up` would fail to pull it on a fresh host (it works only where the image is already cached). The unit and contract suites mock S3, so the pod runs without minio and all 514 tests pass. `api-tests.sh` starts minio only when `MINIO_IMAGE` is set. A project decision is needed if S3-backed tests are ever wanted (options: a mirrored image kept in a registry the project controls, or an S3 stub such as moto server).

D3. **Workspace packages must be built before live tests and web type checks** (measured above). `node-tests.sh` has a `build-libs` step for this and `all` runs it.

D4. **pnpm 11 ignores `npm_config_store_dir`.** It silently placed the 1.1 GB store at `/work/.pnpm-store` inside the source tree, leaving the `plane-pnpm-store` volume with only the corepack cache. The variable that works is `pnpm_config_store_dir` (verified with `pnpm store path`). `.pnpm-store` is not in upstream's `.gitignore` or `.dockerignore`, so an accidental in-tree store would be committed and sent in every image build context. `sync.ps1` now also excludes it. The `build` and `dist` excludes are anchored to the top level, so a nested tracked `build/` or `dist/` directory is not dropped.

D5. Smaller notes:

- The `builder` stage of `Dockerfile.web` and `Dockerfile.live` runs `corepack enable pnpm && pnpm add -g turbo` before any `package.json` is copied in, so corepack picks the latest pnpm (12.8.1 on this date), not the pinned 11.3.0. Later stages get 11.3.0. It worked, but the first stage is not reproducible. A fork that wants deterministic builds can add `corepack prepare pnpm@11.3.0 --activate` there; that is a change to an upstream file, so it would have to be listed in `PATCHES.md`.
- Base images float: `node:22-alpine` (v22.23.3 here) and `nginx:1.31-alpine` (nginx 1.31.6). Pin digests if bit-for-bit repeatability matters.
- Do not run the recipe from Git Bash without `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`; it rewrites leading `/` arguments passed to `wsl.exe`.
- Inside a double-quoted `bash -c "..."` loop, `$var` is expanded by the outer shell first. Put loops in a script file (this cost one repeated run during the spike).
- Web image build-time RAM (2.9-3.2 GB) is well inside the 16 GB VM. No OOM, no `NODE_OPTIONS` or `.wslconfig` change was needed or applied.
- Running the whole recipe at once (web 209 s + live 245 s + api 4 s + api tests 186 s + node 125 s) is about 13 minutes of wall time when run in series.

## Recipe for LU-08 (exact commands)

Run from an existing shell. Never `Start-Process`, never `-WindowStyle`. Check `(Get-Process WindowsTerminal,OpenConsole -EA SilentlyContinue).Count` before and after.

```
# in Git Bash (binary-safe pipes)
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W="wsl.exe -d <distro> -u root --"

# 1. ship a clean tree of the fork branch (includes fork/)
git -C <repo> -c core.autocrlf=false archive --format=tar <branch> | \
  $W sh -c "rm -rf /root/plane-build/src && mkdir -p /root/plane-build/src && tar -x -C /root/plane-build/src"
#    or, for uncommitted work, from PowerShell:  <repo>\fork\test\sync.ps1 -Source <repo>   (-> /root/plane-work)

# 2. build (context = repo root; measure.sh logs free -m every 5 s and prints wall time and peak RAM)
$W bash -c "cd /root/plane-build/src && \
  fork/test/measure.sh web  podman build --cpu-period=100000 --cpu-quota=800000 -f apps/web/Dockerfile.web   -t localhost/plane-fork-web:<tag>  . && \
  fork/test/measure.sh live podman build --cpu-period=100000 --cpu-quota=800000 -f apps/live/Dockerfile.live -t localhost/plane-fork-live:<tag> . && \
  podman build -f fork/docker/Dockerfile.fork-api -t localhost/plane-fork-api:<tag> ."
#    web and live take NO build args. The api overlay needs docker.io/makeplane/plane-backend:v1.4.2 pulled once.

# 3. live smoke test (starts a valkey sidecar in a pod, publishes nothing, prints "HTTP 200 {...}")
$W bash -c "cd /root/plane-build/src && fork/test/live-smoke.sh localhost/plane-fork-live:<tag>"

# 4. api overlay checks
$W podman run --rm -e SECRET_KEY=x -e DATABASE_URL=postgresql://u:p@127.0.0.1:5432/db -e REDIS_URL=redis://127.0.0.1:6379/ localhost/plane-fork-api:<tag> python manage.py check
$W sh -c "podman run --rm docker.io/makeplane/plane-backend:v1.4.2 pip freeze | sort > /tmp/a; podman run --rm localhost/plane-fork-api:<tag> pip freeze | sort > /tmp/b; diff /tmp/a /tmp/b && echo IDENTICAL"

# 5. tests (PLANE_SRC defaults to /root/plane-work; point it at /root/plane-build/src for a clean tree)
$W bash -c "PLANE_SRC=/root/plane-build/src /root/plane-build/src/fork/test/api-tests.sh"          # 514 passed expected on v1.4.2
$W bash -c "PLANE_SRC=/root/plane-build/src /root/plane-build/src/fork/test/node-tests.sh all"     # install, build-libs, live-test, live-types, web-types, web-lint

# 6. ship to the runtime host
$W podman save -m --format docker-archive -o /root/plane-build/images.tar localhost/plane-fork-web:<tag> localhost/plane-fork-live:<tag> localhost/plane-fork-api:<tag>
#    load on the target with: podman load -i images.tar   (or gzip -6 first: 427 MB instead of 1.46 GiB)
```

Set the exec bit on the scripts when committing (`git update-index --chmod=+x fork/test/*.sh`) so a `git archive` tree can run them directly.

Cleanup done at the end of the spike: the spike images (`plane-fork-web:spike`, `plane-fork-web:touch`, `plane-fork-live:spike`, `plane-fork-api:spike`) and all dangling build layers were removed, along with the 1.5 GB image tar, the throwaway source tree `/root/plane-build/spike` (with its node_modules) and the probe cache. No containers or pods remain. Kept: the pulled base images (`node:22-alpine`, `nginx:1.31-alpine`, `alpine:3.20`, `makeplane/plane-backend:v1.4.2`, `makeplane/plane-frontend:v1.4.2`, `postgres:15.7-alpine`, `valkey:7.2.11-alpine`, `rabbitmq:3.13.6-management-alpine`), the volume `plane-pnpm-store` (1.1 GB store plus corepack cache), the buildah pnpm cache mount, the logs in `/root/plane-build/logs`, and the `/root/plane-work` sync target. podman also created `localhost/podman-pause` (742 kB), the pod infra image; it is needed by any pod and was left in place.

## Files added by this spike

- `fork/SPIKE.md` (this file)
- `fork/PATCHES.md` (no upstream file was modified)
- `fork/test/sync.ps1`, `fork/test/measure.sh`, `fork/test/api-tests.sh`, `fork/test/node-tests.sh`, `fork/test/live-smoke.sh`
- `fork/test/cache-probe/Containerfile`
- `fork/docker/Dockerfile.fork-api`
