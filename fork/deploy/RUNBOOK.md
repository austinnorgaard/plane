<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Deploy runbook: live updates and pages API

Every host-specific value is a variable supplied by the operator at run time. Nothing on this page is a real hostname, address, container number or path.

## Updates (normal path)

PLN-109. Code changes reach production as an update: CI builds the images, and one command pulls them and restarts only the services whose image changed. There is no build on the production box, no restart of the other services, and no restart of the container. The numbered sections further down are the first-deploy and offline (archive) procedure. Use them only for that, or when CI is unavailable.

**Prerequisite, once per workstation:** `gh` is logged in to github.com, and its token has the `read:packages` scope (the images are private packages):

```
gh auth refresh -h github.com -s read:packages
gh auth status        # "Token scopes" must list 'read:packages'
```

Nothing is stored on the container. Each `update.sh` step that talks to ghcr.io does the following:

- pipes the token from `gh auth token` over ssh into `pct exec` stdin;
- runs `docker login ghcr.io --password-stdin` with `DOCKER_CONFIG` pointing at a fresh 0700 directory `/run/plane-update.<id>` inside the container (tmpfs);
- removes that directory in a trap on every exit, including Ctrl-C.

The token never appears in an argument list, a log, a file in the repo or the `--dry-run` output.

1. **CI build.** Merge the PR into `live-updates/v1.4.3`. The `Fork images` workflow (`.github/workflows/fork-images.yml`) builds only the images whose paths changed (mapping in `fork/build/service-paths.sh`). It pushes them as `ghcr.io/austinnorgaard/plane-fork-<web|live|api>:sha-<sha>` and moves `:live-updates-v1.4.3`. Its job summary lists the decision and a manifest table (sha, built images, digests). The same manifest is the run artifact `fork-images-manifest`. To build by hand (for example `services=all` for the first switch):
   ```
   gh workflow run fork-images.yml -R austinnorgaard/plane --ref live-updates/v1.4.3 -f services=all -f sha=<sha>
   ```
2. **Update.** From a workstation with this repository checked out, and `PVE_HOST`, `PLANE_CTID` and `PLANE_APP_DIR` set:

   ```
   fork/deploy/update.sh --dry-run <sha>     # prints the plan and every command
   fork/deploy/update.sh <sha>               # or: --services web,live,api
   ```

   **Preflight:** it checks that the sha is on the branch, that the CI run succeeded, that the images exist (with `docker manifest inspect` inside the container) and that no L1 file is active.

   **Then it:**
   - records the current tags (`plane.env.update-prev`, plus a timestamped copy);
   - pulls the changed images;
   - runs the Django migrations with the new api image, if api changes, before any restart;
   - writes `FORK_*_TAG` into `plane.env`;
   - runs `up -d --no-deps` on only the changed services;
   - polls health (web `/`, live `/live/health`, api `/api/instances/` with up to 15 minutes).

   **Hold window:** with `--notify`, `UPDATE_PRE_CMD` runs before the pull and `UPDATE_POST_CMD` after the health checks (locally, `bash -c`), for example to message the Gavel team.

   **Exit codes:**
   - 2: a check stopped it;
   - 4: the registry refused the token (scope);
   - 5: the health check failed. Nothing is rolled back automatically.

3. **Checks.** Run `fork/deploy/update.sh status` (tags, previous tags, running images). Then the post-deploy log check (section 7a), and the smoke tests of section 7 that touch what changed.
4. **Undo.** `fork/deploy/update.sh rollback` puts back the tags from before the last update or rollback (run it twice to roll forward again). It does not reverse migrations.

`gate.sh` (section 1a) checks an image archive and stays the gate for the archive path. For updates, the preflight of `update.sh` takes its place.

### One-time switch from `localhost/...:v1.4.3-live.N` to GHCR tags

Do this once on the container that still runs the archive-built images. Run the steps in `$PLANE_APP_DIR`; `N` is the `FORK_N` now in `plane.env`.

1. Keep copies: `cp -p docker-compose.override.yaml docker-compose.override.yaml.pre-pln109 && cp -p plane.env plane.env.pre-pln109`.
2. Add the per-service tags for the images that are running now. Append them with an editor or `printf`; never print `plane.env`:
   ```
   FORK_REGISTRY=localhost
   FORK_WEB_TAG=v1.4.3-live.N
   FORK_LIVE_TAG=v1.4.3-live.N
   FORK_API_TAG=v1.4.3-live.N
   ```
   The `FORK_N` line can stay; nothing reads it any more.
3. Copy the new `fork/deploy/docker-compose.override.yaml` into `$PLANE_APP_DIR` (as in section 4). It also carries the Gunicorn hotfix (`GUNICORN_CMD_ARGS`, `GUNICORN_WORKERS: "2"` on api). If the hotfix was applied somewhere else on the container, remove it there, so that the override is its only source: `grep -n GUNICORN docker-compose*.yaml`.
4. Validate with `$C config -q && echo config-ok`, then run `fork/deploy/rollback.sh forward` from the workstation. It runs `up -d` (a no-op for unchanged services) and checks that the five services run `localhost/plane-fork-*:v1.4.3-live.N`, the images plane.env now names.
5. Build all three images for the branch head in CI (step 1 above, `services=all`), then run `fork/deploy/update.sh <head sha>`. The registry changes, so all three images move to `ghcr.io/austinnorgaard/...:sha-<head sha>`. `update.sh rollback` returns to the localhost images, as long as they are still in the local store (keep them until the GHCR images have run for a while).

After the switch, `fork/build/build.sh` is the offline fallback only. Its images are deployed by setting `FORK_REGISTRY=localhost` and the three tags to `v1.4.3-live.<N>`, then running `$C up -d`.

| Variable                       | Meaning                                                                                                                                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PVE_HOST`                     | ssh target of the hypervisor                                                                                                                                                                      |
| `PLANE_CTID`                   | container id of the Plane container on the hypervisor                                                                                                                                             |
| `PLANE_APP_DIR`                | path in the container to the plane-app directory, which holds `docker-compose.yaml` and `plane.env`                                                                                               |
| `PAUSE_FLAG_PATH`              | path of the flag file that pauses automated changes (operator supplied)                                                                                                                           |
| `PVE_STAGING_DIR`              | scratch directory on the hypervisor for the image archive                                                                                                                                         |
| `CT_STAGING_DIR`               | scratch directory in the container for the image archive                                                                                                                                          |
| `BUILD_HOST`                   | machine where the images were built with podman                                                                                                                                                   |
| `STOCK_RELEASE`                | tag of the stock `makeplane/*` images running before the deploy, taken from the inspection                                                                                                        |
| `FORK_N`                       | build number of an archive build (`build.sh`); its tag is `v1.4.3-live.$FORK_N`. The override reads `FORK_REGISTRY` and `FORK_WEB_TAG` / `FORK_LIVE_TAG` / `FORK_API_TAG` instead (see "Updates") |
| `PUBLIC_URL`                   | origin users open from outside the LAN                                                                                                                                                            |
| `LAN_URL`                      | origin users open from the LAN                                                                                                                                                                    |
| `WORKSPACE_SLUG`, `PROJECT_ID` | a test workspace and project for the health checks                                                                                                                                                |
| `PLANE_API_TOKEN`              | a Plane API token of a test user, exported in your shell only, never printed or committed                                                                                                         |

Compose shorthand used below, run inside the container in `$PLANE_APP_DIR`:

```
C="docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env"
```

Never run `$C config` without `-q` on the server: it prints every secret.

## 0. Plan and window

Sections 0 to 12 are the full first-install procedure with an image archive (`fork/build/build.sh`, offline path). For a
normal update of a running fork deployment use "Updates (normal path)" above; sections 7, 7a, 10 and 11 still apply after it.

One maintenance window covers: deploy, the post-deploy health checks, and a rehearsal of rollback L1 and L2 followed by a roll-forward. Rollback L3 is described but not rehearsed. Budget about 60 to 90 minutes, dominated by the image transfer.

Do not use the community installer (`setup.sh`) at any point. It starts the stack with an explicit `-f` and silently reverts to stock images. See `README.fork`.

## 1. Inspect (read-only)

From a workstation with this repository checked out:

```
ssh "$PVE_HOST" "PLANE_CTID=$PLANE_CTID PLANE_APP_DIR=$PLANE_APP_DIR bash -s" < fork/deploy/inspect.sh
```

Exit 0 means no STOP lines. Exit 2 means at least one STOP line: do not continue; escalate to the owner. STOP cases:

- `LIVE_SERVER_SECRET_KEY` is the shipped placeholder, empty or undefined. Rotating it is the owner's decision.
- `LIVE_BASE_URL` is already set on `worker` or `beat-worker`: the page-duplicate live sync would already be active.
- `worker` or `beat-worker` is not running, so `LIVE_BASE_URL` cannot be verified.
- The compose file mentions `LIVE_BASE_URL` at all (the stock file does not).

Fill in the table below from the output (values `set`, `unset`, `match`, `no-match`, `works`, `fails`; URLs only as the variable names `PUBLIC_URL` / `LAN_URL`; no addresses, hostnames or secrets). Also record the origins users actually use as `PUBLIC_URL` and `LAN_URL` for step 5.

### Inspection results

| Item                                                   | Result |
| ------------------------------------------------------ | ------ |
| Compose file name in `$PLANE_APP_DIR`                  |        |
| Image line: web                                        |        |
| Image line: live                                       |        |
| Image line: api                                        |        |
| Image line: worker                                     |        |
| Image line: beat-worker                                |        |
| `plane.env` defines `WEB_URL`                          |        |
| `WEB_URL` equals `PUBLIC_URL` / `LAN_URL` / other      |        |
| `LIVE_SERVER_SECRET_KEY` state (sha256 vs placeholder) |        |
| `LIVE_BASE_URL` in `plane.env`                         |        |
| `LIVE_BASE_URL` on running api                         |        |
| `LIVE_BASE_URL` on running worker (must be unset)      |        |
| `LIVE_BASE_URL` on running beat-worker (must be unset) |        |
| `plane-redis` publishes ports                          |        |
| `pct listsnapshot` works                               |        |
| `STOCK_RELEASE` (tag of the stock images now running)  |        |
| Free disk in `$PLANE_APP_DIR` filesystem               |        |
| Free disk for the container image store                |        |
| Origins users use (variable names only)                |        |
| inspect.sh exit code                                   |        |

Free disk must exceed twice the size of the image archive (about 1.5 GB for the three fork images).

## 1a. Go/no-go gate (before any change)

Run this on the workstation with this repository checked out, after step 1 and before step 2. It changes nothing and prints one PASS or FAIL line per item, then `RESULT: GO` (exit 0) or `RESULT: NO-GO` with the failing items (exit 1). Do not start step 2 unless it prints GO. A bad argument exits 2.

Inputs, all supplied by you at run time (no secret is ever printed; only key names):

| Input                                     | Meaning                                                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `RELEASE_SHA`                             | argument: the full sha being deployed                                                                                                |
| `IMAGE_TAR`, `IMAGE_SHA256`               | the archive and the sha256 from the build output (or `BUILD_NOTES`, a file with the `Tar sha256:` line)                              |
| `RUNBOOK_FILE`                            | your copy of this file with the inspection table above filled in (default: the shipped file, which fails because its table is empty) |
| `STOCK_RELEASE`                           | the stock image tag from the inspection, used by rollback L2                                                                         |
| `PVE_HOST`, `PLANE_CTID`, `PLANE_APP_DIR` | as in step 1; the gate runs `inspect.sh` the same way                                                                                |
| `ENV_FILE`                                | a copy of the deploy settings (`plane.env`), passed with `-e`; without `-e` they are read from the environment                       |

```
IMAGE_TAR=<archive> IMAGE_SHA256=<hash> RUNBOOK_FILE=<filled copy> STOCK_RELEASE=<tag> \
  PVE_HOST=$PVE_HOST PLANE_CTID=$PLANE_CTID PLANE_APP_DIR=$PLANE_APP_DIR \
  bash fork/deploy/gate.sh -e <env-file-copy> <release-sha>
```

Checks, each a PASS or a FAIL:

- the release sha is an ancestor of `origin/live-updates/v1.4.3` (the gate fetches that branch first);
- the archive sha256 matches the build output (done by `fetch-images.sh` with `SKIP_LOAD=1`, which copies the archive to a temporary directory, so keep free disk for one more copy; nothing is loaded);
- the archive is bound to the release sha: every image in it carries the label `plane-fork-build=<sha>` that `build.sh` sets (read from the archive manifest and image configs; nothing is loaded). If you pass the saved build output as `BUILD_NOTES`, its `SHA verified: <sha>` line must also name the release sha. Notes alone bind the archive only with both the `SHA verified:` line and a `Tar sha256:` line equal to `IMAGE_SHA256`. An archive with no label and no usable notes is a FAIL. Known limitation: `::/16` passes the IPv6 range floor although it covers the IPv4-mapped range;
- every row of the inspection table has a result;
- `LIVE_EVENTS_TRUSTED_PROXIES` is non-empty and every entry is an address or CIDR range (ranges wider than /8 for IPv4 or /16 for IPv6 are refused);
- `PAGES_REBASE_MAX_HTML_BYTES` is at least `PAGES_API_MAX_HTML_BYTES` (unset values count as the code defaults, 524288 and 262144);
- `PAGES_REBASE_WORKER_MAX_MB` is between 64 and 4096 (unset is the code default, 256);
- `NODE_OPTIONS` has no `--max-old-space-size`;
- `LIVE_SERVER_SECRET_KEY` is set and neither is nor contains the shipped placeholder (whitespace and an unquoted `# comment` tail are removed first, as compose does);
- `inspect.sh` exits 0 (`PLANE_CTID` must be digits and `PLANE_APP_DIR` a safe absolute path, else nothing is sent; ssh runs with `BatchMode` and a timeout (the `timeout` command must exist, else the item FAILs and inspect.sh is not run), `GATE_INSPECT_TIMEOUT` seconds overall, default 300);
- rollback is available: the five L1 flag lines are in the override, and `STOCK_RELEASE` is set and is not a fork tag.

Any FAIL means stop and fix the item or escalate; there is no override. Without `-e`, a `NODE_OPTIONS` in your own shell is read too.

## 2. Pause and snapshot

1. Pause automated changes: create the pause flag at `$PAUSE_FLAG_PATH` on the machine that owns it. Remove it only in step 12.
2. Snapshot (on the hypervisor):

```
ssh "$PVE_HOST" "pct snapshot $PLANE_CTID pre-live-$FORK_N && pct listsnapshot $PLANE_CTID"
```

3. Back up the files that will change (in the container):

```
cp -p docker-compose.yaml docker-compose.yaml.pre-live-$FORK_N
cp -p plane.env plane.env.pre-live-$FORK_N
```

## 3. Transfer the images

Chosen path: the image archive built in the cloud is published as an asset of a release of this repository, and the deploy host downloads it and checks its sha256 before anything is loaded. The archive is about 0.5 GB today; check it against the 2 GiB per-asset limit of a release (step a). If it ever approaches the limit, switch to a registry instead of splitting the file.

The images are built from this public repository, and the build secrets (such as a CA bundle) are mounted only during the build and are not stored in any layer, so a public asset exposes nothing that the source does not. Confirm that with `podman history --no-trunc` on the three images if the build setup changed. Downloading a public release asset needs no credential.

Additional variables:

| Variable       | Meaning                                                                     |
| -------------- | --------------------------------------------------------------------------- |
| `FORK_REPO`    | `owner/name` of this fork on GitHub                                         |
| `RELEASE_TAG`  | tag of the image release, one per build, for example `images-live.$FORK_N`  |
| `IMAGE_SHA256` | sha256 of the archive, copied from the build output (the `Tar sha256` line) |

The expected hash must come from the build output, not from the release page: that is what makes the check independent of the download.

a. Publish (an owner step, done once per build, never part of the deploy window). `build.sh` writes `plane-fork-live.$FORK_N.tar` and `.sha256`. Then:

```
ls -l plane-fork-live.$FORK_N.tar          # must be below 2 GiB (2147483648 bytes)
cat plane-fork-live.$FORK_N.sha256         # note IMAGE_SHA256
gh release create "$RELEASE_TAG" --repo "$FORK_REPO" --title "$RELEASE_TAG" \
  --notes "Image archive for fork build $FORK_N. sha256 in the build record." \
  plane-fork-live.$FORK_N.tar plane-fork-live.$FORK_N.sha256
```

The `.sha256` asset is a convenience copy. Never trust it alone: compare against `IMAGE_SHA256` from the build output.

b. Fetch, verify and load on the deploy host (the container, which has docker and must also have `curl`; if it has no `curl` or no internet access, use step c). `pct push` copies single files and creates no directories, so push both scripts flat into `$CT_STAGING_DIR`:

```
ssh "$PVE_HOST" "pct push $PLANE_CTID <path-to-repo>/fork/deploy/fetch-images.sh $CT_STAGING_DIR/fetch-images.sh"
ssh "$PVE_HOST" "pct push $PLANE_CTID <path-to-repo>/fork/build/verify-load.sh $CT_STAGING_DIR/verify-load.sh"
```

(copy the two files to the hypervisor first if the repository is not checked out there). Then run the flat path with `VERIFY_LOAD` set:

```
ssh "$PVE_HOST" "pct exec $PLANE_CTID -- env CONTAINER_ENGINE=docker FORK_N=$FORK_N \
  VERIFY_LOAD=$CT_STAGING_DIR/verify-load.sh \
  bash $CT_STAGING_DIR/fetch-images.sh \
  https://github.com/$FORK_REPO/releases/download/$RELEASE_TAG/plane-fork-live.$FORK_N.tar \
  $IMAGE_SHA256 $CT_STAGING_DIR"
```

The script downloads to a temporary file, compares the sha256 with `IMAGE_SHA256`, and on a mismatch deletes the download, prints `sha256 mismatch` and exits 1: stop and do not retry with another hash; rebuild or republish instead. On a match it stores the archive and a `.sha256` file, then runs `verify-load.sh`, which checks the hash again, loads the archive and confirms the three `localhost/plane-fork-*:v1.4.3-live.$FORK_N` names. It prints `All checks passed` and exits 0 only if all of that succeeded.

c. If the container cannot reach the internet, run step b on any machine that can, with `SKIP_LOAD=1` (it verifies and stores the archive and writes the `.sha256` file, and does not load). Copy both files into the container (`pct push`) and run the flat `verify-load.sh` there (push it as in step b):

```
ssh "$PVE_HOST" "pct exec $PLANE_CTID -- env CONTAINER_ENGINE=docker \
  bash $CT_STAGING_DIR/verify-load.sh $CT_STAGING_DIR/plane-fork-live.$FORK_N.tar $CT_STAGING_DIR/plane-fork-live.$FORK_N.sha256"
```

Confirm with `docker image ls 'localhost/plane-fork-*'`. Delete the downloaded archive afterwards; keep the release for rollback.

Rollback of the delivery itself: nothing changes on the host until step 6 starts the new tag, so a bad archive is simply discarded. To go back to an earlier build, repeat step b with that build's `RELEASE_TAG` and hash, or use rollback L1 and L2 below. Never delete an old release while a deployment may still need it.

Manual alternative (no release, no internet on the build side): copy the archive with `scp`, run `sha256sum` on each hop and compare each result with `IMAGE_SHA256`, then run `fetch-images.sh` with the local path as SOURCE (it re-checks the hash and calls `verify-load.sh`).

## 4. Install the override

Copy `fork/deploy/docker-compose.override.yaml` into `$PLANE_APP_DIR` (`pct push`, same as above) and add these keys to `plane.env` (set values yourself; do not paste secrets anywhere):

```
FORK_REGISTRY=localhost
FORK_WEB_TAG=v1.4.3-live.<FORK_N>
FORK_LIVE_TAG=v1.4.3-live.<FORK_N>
FORK_API_TAG=v1.4.3-live.<FORK_N>
LIVE_EVENTS_ALLOWED_ORIGINS=<PUBLIC_URL>,<LAN_URL>
```

(These are the archive images. With CI images, leave `FORK_REGISTRY` out (the default is `ghcr.io/austinnorgaard`) and use `sha-<sha>` tags; normally `update.sh` writes them.)

`WEB_URL` must already be defined in `plane.env` (see inspection). `CORS_ALLOWED_ORIGINS` stays as it is; the override never passes it into live.

## 5. Validate

Validate quietly (prints nothing on success, and never prints values):

```
$C config -q && echo config-ok
```

Do not continue unless `config-ok` is printed.

## 6. Apply, image-tag check and env key-name check

```
$C up -d
$C ps --format '{{.Service}} {{.Image}}'
```

Expected images: `web`, `live`, `api`, `worker`, `beat-worker` all `$FORK_REGISTRY/plane-fork-*:<tag>` with the tags from `plane.env` (archive path: `localhost/plane-fork-*:v1.4.3-live.$FORK_N`; web -> `plane-fork-web` with `FORK_WEB_TAG`, live -> `plane-fork-live` with `FORK_LIVE_TAG`, the other three -> `plane-fork-api` with `FORK_API_TAG`). Every other service keeps its stock image. Exactly one `live` container must be running. If any of the five shows a stock image, the stack was started without the override (for example through `setup.sh`): rerun `$C up -d`.

Wait for `api` to be healthy: `$C logs --tail 30 api`.

### Env key-name check (after the apply)

Env key-name check on the running containers. These print names, never values:

```
for s in live api worker beat-worker; do
  echo "== $s"; $C exec -T $s sh -c 'env | cut -d= -f1' | sort | grep -xE 'LIVE_EVENTS_ENABLED|LIVE_EVENTS_ALLOWED_ORIGINS|WEB_URL|PAGES_API_ENABLED|LIVE_SERVER_SECRET_KEY|LIVE_BASE_URL|CORS_ALLOWED_ORIGINS'
done
```

Expected:

| Service       | Names present                                                                                                  | Names absent                            |
| ------------- | -------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| `live`        | `LIVE_EVENTS_ENABLED`, `LIVE_EVENTS_ALLOWED_ORIGINS`, `WEB_URL`, `PAGES_API_ENABLED`, `LIVE_SERVER_SECRET_KEY` | `CORS_ALLOWED_ORIGINS`, `LIVE_BASE_URL` |
| `api`         | `LIVE_EVENTS_ENABLED`, `PAGES_API_ENABLED`, `LIVE_BASE_URL`, `LIVE_SERVER_SECRET_KEY`                          |                                         |
| `worker`      | `LIVE_EVENTS_ENABLED`                                                                                          | `LIVE_BASE_URL`, `PAGES_API_ENABLED`    |
| `beat-worker` |                                                                                                                | `LIVE_BASE_URL`, `PAGES_API_ENABLED`    |

If `LIVE_BASE_URL` shows on `worker` or `beat-worker`, run rollback L1 (below) at once and stop.

## 7. Post-deploy health checks

Live updates:

1. `$C exec -T live node -e "fetch('http://127.0.0.1:3000/live/health').then(async r=>{console.log(r.status,await r.text())})"` prints `200`.
2. Open Plane at `$PUBLIC_URL` (or `$LAN_URL`) in two browsers as two users in the same project; hard-reload both first (see step 9). In the browser developer tools the `/live/events` WebSocket is connected (status 101).
3. In browser A change a work item (state, then assignee, then create and delete one). Browser B updates within a few seconds without a reload.
4. Repeat step 3 from the LAN origin if both origins are in use: the socket must connect from each.
5. A bulk change (select several items, change state) updates in B.

Pages API (uses a test workspace and project; the token is read from the shell and never echoed):

```
B="$PUBLIC_URL/api/v1/workspaces/$WORKSPACE_SLUG/projects/$PROJECT_ID/pages"
H="X-API-Key: $PLANE_API_TOKEN"
curl -sS -H "$H" "$B/"                                                    # list: 200
curl -sS -H "$H" -H 'Content-Type: application/json' -d '{"name":"smoke page","description_html":"<p>hello</p>"}' "$B/"   # create: 201, note the id
curl -sS -H "$H" "$B/<id>/"                                               # retrieve: 200
curl -sS -X PATCH -H "$H" -H 'Content-Type: application/json' -d '{"description_html":"<p>changed</p>"}' "$B/<id>/"        # not open anywhere: 200
```

Then open that page in a browser and repeat the PATCH: it must return `409 {"error": "page is open in an editor; retry later"}` and change nothing. Close every tab of the page and PATCH again: 200. Then archive (`POST $B/<id>/archive/`) and unarchive (`DELETE $B/<id>/archive/`). Delete the smoke page from the UI afterwards.

Live-side guard checks (from inside `api`, so no public route is involved; the key is read from the container's own environment):

```
$C exec -T api python -c "import os,requests;h={'live-server-secret-key':os.environ['LIVE_SERVER_SECRET_KEY']};print(requests.get('http://live:3000/live/fork/pages/00000000-0000-0000-0000-000000000000/loaded',headers=h,timeout=3).text)"
```

prints `{"loaded":false}`. With an added header `X-Forwarded-For: 1.2.3.4` the same request returns 404 (403 before PLN-99).

Guard checks without the key (both must match exactly; any other status means the guard is not what the code says, so run rollback L1 and escalate):

```
# direct to live, no secret header: 404 (401 before PLN-99)
$C exec -T api python -c "import requests;print(requests.get('http://live:3000/live/fork/pages/00000000-0000-0000-0000-000000000000/loaded',timeout=3).status_code)"
# public route through the proxy, no key: 404 (403 before PLN-99)
curl -sS -o /dev/null -w '%{http_code}\n' "$PUBLIC_URL/live/fork/pages/00000000-0000-0000-0000-000000000000/loaded"
```

Why: since PLN-99 the live guard (`apps/live/src/fork-pages/auth.ts`) answers every refusal with the same 404 `{"message": "Not Found"}`: a missing or wrong `live-server-secret-key`, an unusable configured key, or a request that carries `X-Forwarded-For` or `X-Forwarded-Host`. The proxy adds `X-Forwarded-For` to everything it forwards, so the public route is 404 with or without a key. The live log names the cause (`FORK_PAGES: request refused: ...`, at most once a minute per cause). A 200 on either call means the guard is broken. Repeat the second call from `$LAN_URL`.

Duplicate a page in the UI: it must still work and the copy must open normally (the worker has no `LIVE_BASE_URL`, so the live sync stays off).

### 7a. Post-deploy log check

After the health checks, and again 15 minutes later, run from a workstation (same variables as `rollback.sh`):

```
fork/deploy/postdeploy-logs.sh --window 15m
```

It reads `docker compose logs --since` for api, worker, beat-worker and live and prints counts (5xx, 503, page PATCH 409 loaded versus unknown (loaded is an upper bound and unknown a lower bound: unknown counts only the presence checks the api logged as failed), "live write lock ... expired before it was released" warnings (PLN-98; older builds logged "opened in an editor during an api update"), tracebacks, live errors, close codes 4401, 4403, 4429, 1013, rate-limit overflows) plus the top distinct error lines with emails, addresses, ids and credentials redacted. Exit 0 is clean, 1 is over a threshold (investigate, and consider rollback L1), 2 is a usage or validation error, 3 means the logs could not be read, which is not a pass. Thresholds are options (`--help`); `--dry-run` prints the command. Needs GNU sed 4.x (the script checks and exits 2 if it is missing), GNU `timeout` and `mktemp` on the workstation; awk was tested with mawk. The overall limit uses `timeout --foreground`, so Ctrl-C stops the run. A quiet counter line such as `errors=0` is not counted.

## 8. Rehearsal of rollback L1 and L2, then roll forward

Targets are estimates; record the measured times here.

| Step         | Target       | Measured |
| ------------ | ------------ | -------- |
| L1           | 1 to 2 min   |          |
| L2           | 60 s or less |          |
| Roll forward | 1 to 2 min   |          |

## 9. Hard reload

The web bundle changed. Tabs opened before the deploy keep running the old code (no live updates) until reloaded. Tell users to hard-reload once (Ctrl+Shift+R, or Cmd+Shift+R). After L2 or L3 do the same, otherwise a tab may keep calling code the stock server does not have.

## 10. Rollback

Choose the smallest level that fixes the problem.

**Wrapper.** `fork/deploy/rollback.sh l1|l2|forward` runs the commands of L1, L2 and the roll-forward below, in the same order, with the sed check and a timing line per step. Run it from a workstation with `PVE_HOST`, `PLANE_CTID` and `PLANE_APP_DIR` set (plus `STOCK_RELEASE` for `l2`; `forward` reads the image tags from `plane.env`). `--dry-run` prints every command and changes nothing. Exit codes: 0 done, 1 usage, 2 a check failed (nothing further was run), 3 a remote command failed. It is idempotent: running `l1` twice is safe.

```
fork/deploy/rollback.sh --dry-run l1
fork/deploy/rollback.sh l1
```

`l2` also checks first that every stock image that uses `APP_RELEASE` (backend, frontend, space, admin, live, proxy) is in the local store at `$STOCK_RELEASE`, warns when the up takes longer than 60 s, and exits 2 if any service still shows a `plane-fork-` image (GHCR or localhost) afterwards. The ssh calls use `BatchMode`, `ConnectTimeout=10` and a keepalive, so a dead host fails fast. `forward` checks that the five fork services run the images `plane.env` names (`FORK_REGISTRY` and the `FORK_*_TAG` lines) and deletes the L1 file only if they do. The manual commands below are the fallback and stay the reference.

**L1: both flags off (about 1 to 2 min).** Keeps the fork images, turns the behaviour off. Live events stop (the socket closes with 4404) and the pages API answers 404. The L1 file is generated on the spot and deleted after the roll-forward.

```
sed -e 's/LIVE_EVENTS_ENABLED: "1"/LIVE_EVENTS_ENABLED: "0"/' \
    -e 's/PAGES_API_ENABLED: "1"/PAGES_API_ENABLED: "0"/' \
    docker-compose.override.yaml > docker-compose.override.l1.yaml
off=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): "0"$' docker-compose.override.l1.yaml)
on=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): ' docker-compose.override.l1.yaml | tr -d ' ')
left=$(grep -cE '^ +(LIVE_EVENTS_ENABLED|PAGES_API_ENABLED): .*1' docker-compose.override.l1.yaml)
if [ "$off" = 5 ] && [ "$on" = 5 ] && [ "$left" = 0 ]; then
  docker compose -f docker-compose.yaml -f docker-compose.override.l1.yaml --env-file plane.env up -d api worker live
else
  echo "STOP: expected exactly 5 flag lines set to \"0\" (3 LIVE_EVENTS_ENABLED + 2 PAGES_API_ENABLED) and none left on; got off=$off left=$left. Do not run up; edit the L1 file by hand and recheck."
fi
```

Roll forward (`rollback.sh forward`, or by hand): rerun step 6 with the normal override, then `rm docker-compose.override.l1.yaml`.

After any rollback level or the roll forward, run `fork/deploy/postdeploy-logs.sh --window 10m` (step 7a) once the services are up. Exit 0 means no 5xx, tracebacks or live errors above the thresholds; exit 3 means the logs were not read.

**L2: stock images (target 60 s or less, measured with `time`).** Run the stack from the upstream file alone. The stock images `makeplane/*` are still in the local image store because they are never pruned. `STOCK_RELEASE` is the tag recorded in the inspection table; check that the images exist before the window (`docker image ls makeplane/plane-backend`).

```
time APP_RELEASE=$STOCK_RELEASE docker compose -f docker-compose.yaml --env-file plane.env up -d --pull never --wait --wait-timeout 60
APP_RELEASE=$STOCK_RELEASE docker compose -f docker-compose.yaml --env-file plane.env ps --format '{{.Service}} {{.Image}}'
```

Every service must show a `makeplane/*:$STOCK_RELEASE` image (or its original stock image). Then hard-reload (step 9). Do not use `setup.sh` for this either. If the time exceeds 60 s in the rehearsal, record it and tell the owner.

**L3: restore the snapshot (about 5 to 10 min, data loss).** Everything written after the snapshot is lost (work items, pages, uploads), so use it only if L2 does not recover the system.

```
ssh "$PVE_HOST" "pct stop $PLANE_CTID && pct rollback $PLANE_CTID pre-live-$FORK_N && pct start $PLANE_CTID"
```

Afterwards run the stock stack as in L2 and check the web UI. Delete the snapshot once the deploy is accepted: `pct delsnapshot $PLANE_CTID pre-live-$FORK_N`.

## 11. Retention

- `fork/deploy/prune-images.sh` (PLN-64) removes old GHCR fork images. Run it from the workstation with the same `PVE_HOST`, `PLANE_CTID` and `PLANE_APP_DIR` as `update.sh`. The default is a dry run that lists each `plane-fork-{web,live,api}:sha-*` image as KEEP or REMOVE with the reason; `--apply` removes the REMOVE ones with `docker image rm <repo>:<tag>`, never `--force`. Per image it keeps the current tag (plane.env), the `update.sh rollback` target (plane.env.update-prev), the most recent other tag (`--keep <n>` keeps more) and any image a container uses. It never touches `makeplane/*`, base images, untagged images or the `localhost/plane-fork-*` archive images. Run it after an update has been accepted.
- Archive path images (`localhost/plane-fork-web:v1.4.3-live.<old>`; and `-live`, `-api`): keep the running one and the previous one, and remove older ones by exact tag with `docker image rm`.
- Never prune stock images: no `docker image prune -a`, no `docker system prune -a`, no removal of `makeplane/*`, `postgres`, `valkey`, `rabbitmq` or `minio` images. Rollback L2 depends on them.
- Delete image archives from `$PVE_STAGING_DIR` and `$CT_STAGING_DIR` after the checksum check.

## 12. Finish

Remove the pause flag at `$PAUSE_FLAG_PATH`. Record the outcome, the measured rollback times and the fork tag now running.
