<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Deploy runbook: live updates and pages API

Every host-specific value is a variable supplied by the operator at run time. Nothing on this page is a real hostname, address, container number or path.

| Variable            | Meaning                                                                                      |
| ------------------- | -------------------------------------------------------------------------------------------- |
| `PVE_HOST`          | ssh target of the hypervisor                                                                 |
| `PLANE_CTID`        | container id of the Plane container on the hypervisor                                        |
| `PLANE_APP_DIR`     | path in the container to the plane-app directory, which holds `docker-compose.yaml` and `plane.env` |
| `PAUSE_FLAG_PATH`   | path of the flag file that pauses automated changes (operator supplied)                      |
| `PVE_STAGING_DIR`   | scratch directory on the hypervisor for the image archive                                    |
| `CT_STAGING_DIR`    | scratch directory in the container for the image archive                                     |
| `BUILD_HOST`        | machine where the images were built with podman                                              |
| `STOCK_RELEASE`     | tag of the stock `makeplane/*` images running before the deploy, taken from the inspection   |
| `FORK_N`            | fork build number; tag is `v1.4.2-live.$FORK_N`                                              |
| `PUBLIC_URL`        | origin users open from outside the LAN                                                       |
| `LAN_URL`           | origin users open from the LAN                                                               |
| `WORKSPACE_SLUG`, `PROJECT_ID` | a test workspace and project for the smoke tests                                  |
| `PLANE_API_TOKEN`   | a Plane API token of a test user, exported in your shell only, never printed or committed    |

Compose shorthand used below, run inside the container in `$PLANE_APP_DIR`:

```
C="docker compose -f docker-compose.yaml -f docker-compose.override.yaml --env-file plane.env"
```

Never run `$C config` without `-q` on the server: it prints every secret.

## 0. Plan and window

One maintenance window covers: deploy, smoke tests, and a rehearsal of rollback L1 and L2 followed by a roll-forward. Rollback L3 is described but not rehearsed. Budget about 60 to 90 minutes, dominated by the image transfer.

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

| Item                                                        | Result |
| ----------------------------------------------------------- | ------ |
| Compose file name in `$PLANE_APP_DIR`                       |        |
| Image line: web                                             |        |
| Image line: live                                            |        |
| Image line: api                                             |        |
| Image line: worker                                          |        |
| Image line: beat-worker                                     |        |
| `plane.env` defines `WEB_URL`                               |        |
| `WEB_URL` equals `PUBLIC_URL` / `LAN_URL` / other           |        |
| `LIVE_SERVER_SECRET_KEY` state (sha256 vs placeholder)      |        |
| `LIVE_BASE_URL` in `plane.env`                              |        |
| `LIVE_BASE_URL` on running api                              |        |
| `LIVE_BASE_URL` on running worker (must be unset)           |        |
| `LIVE_BASE_URL` on running beat-worker (must be unset)      |        |
| `plane-redis` publishes ports                               |        |
| `pct listsnapshot` works                                    |        |
| `STOCK_RELEASE` (tag of the stock images now running)       |        |
| Free disk in `$PLANE_APP_DIR` filesystem                    |        |
| Free disk for the container image store                     |        |
| Origins users use (variable names only)                     |        |
| inspect.sh exit code                                        |        |

Free disk must exceed twice the size of the image archive (about 1.5 GB for the three fork images).

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

| Variable            | Meaning                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------- |
| `FORK_REPO`         | `owner/name` of this fork on GitHub                                                      |
| `RELEASE_TAG`       | tag of the image release, one per build, for example `images-live.$FORK_N`               |
| `IMAGE_SHA256`      | sha256 of the archive, copied from the build output (the `Tar sha256` line)              |

The expected hash must come from the build output, not from the release page: that is what makes the check independent of the download.

a. Publish (an owner step, done once per build, never part of the deploy window). `build.sh` writes `plane-fork-live.$FORK_N.tar` and `.sha256`. After the images pass `fork/test/live-smoke.sh`:

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

The script downloads to a temporary file, compares the sha256 with `IMAGE_SHA256`, and on a mismatch deletes the download, prints `sha256 mismatch` and exits 1: stop and do not retry with another hash; rebuild or republish instead. On a match it stores the archive and a `.sha256` file, then runs `verify-load.sh`, which checks the hash again, loads the archive and confirms the three `localhost/plane-fork-*:v1.4.2-live.$FORK_N` names. It prints `All checks passed` and exits 0 only if all of that succeeded.

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
FORK_N=<number>
LIVE_EVENTS_ALLOWED_ORIGINS=<PUBLIC_URL>,<LAN_URL>
```

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

Expected images: `web`, `live`, `api`, `worker`, `beat-worker` all `localhost/plane-fork-*:v1.4.2-live.$FORK_N` (web -> `plane-fork-web`, live -> `plane-fork-live`, the other three -> `plane-fork-api`). Every other service keeps its stock image. Exactly one `live` container must be running. If any of the five shows a stock image, the stack was started without the override (for example through `setup.sh`): rerun `$C up -d`.

Wait for `api` to be healthy: `$C logs --tail 30 api`.

### Env key-name check (after the apply)

Env key-name check on the running containers. These print names, never values:

```
for s in live api worker beat-worker; do
  echo "== $s"; $C exec -T $s sh -c 'env | cut -d= -f1' | sort | grep -xE 'LIVE_EVENTS_ENABLED|LIVE_EVENTS_ALLOWED_ORIGINS|WEB_URL|PAGES_API_ENABLED|LIVE_SERVER_SECRET_KEY|LIVE_BASE_URL|CORS_ALLOWED_ORIGINS'
done
```

Expected:

| Service       | Names present                                                                                             | Names absent                         |
| ------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `live`        | `LIVE_EVENTS_ENABLED`, `LIVE_EVENTS_ALLOWED_ORIGINS`, `WEB_URL`, `PAGES_API_ENABLED`, `LIVE_SERVER_SECRET_KEY` | `CORS_ALLOWED_ORIGINS`, `LIVE_BASE_URL` |
| `api`         | `LIVE_EVENTS_ENABLED`, `PAGES_API_ENABLED`, `LIVE_BASE_URL`, `LIVE_SERVER_SECRET_KEY`                      |                                      |
| `worker`      | `LIVE_EVENTS_ENABLED`                                                                                      | `LIVE_BASE_URL`, `PAGES_API_ENABLED` |
| `beat-worker` |                                                                                                            | `LIVE_BASE_URL`, `PAGES_API_ENABLED` |

If `LIVE_BASE_URL` shows on `worker` or `beat-worker`, run rollback L1 (below) at once and stop.

## 7. Smoke tests

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

prints `{"loaded":false}`. With an added header `X-Forwarded-For: 1.2.3.4` the same request returns 403.

Guard checks without the key (both must match exactly; any other status means the guard is not what the code says, so run rollback L1 and escalate):

```
# direct to live, no secret header: 401
$C exec -T api python -c "import requests;print(requests.get('http://live:3000/live/fork/pages/00000000-0000-0000-0000-000000000000/loaded',timeout=3).status_code)"
# public route through the proxy, no key: 403
curl -sS -o /dev/null -w '%{http_code}\n' "$PUBLIC_URL/live/fork/pages/00000000-0000-0000-0000-000000000000/loaded"
```

Why: the live guard answers 401 to a request with a missing or wrong `live-server-secret-key` (`apps/live/src/fork-pages/auth.ts`, tests in `apps/live/tests/fork-pages/auth.test.ts`), and answers 403 to any request that carries `X-Forwarded-For` or `X-Forwarded-Host` before it looks at the key. The proxy adds `X-Forwarded-For` to everything it forwards, so the public route is 403 with or without a key. Repeat the second call from `$LAN_URL`.

Duplicate a page in the UI: it must still work and the copy must open normally (the worker has no `LIVE_BASE_URL`, so the live sync stays off).

## 8. Rehearsal of rollback L1 and L2, then roll forward

Targets are estimates; record the measured times here.

| Step | Target | Measured |
| ---- | ------ | -------- |
| L1   | 1 to 2 min |      |
| L2   | 60 s or less |      |
| Roll forward | 1 to 2 min |  |

## 9. Hard reload

The web bundle changed. Tabs opened before the deploy keep running the old code (no live updates) until reloaded. Tell users to hard-reload once (Ctrl+Shift+R, or Cmd+Shift+R). After L2 or L3 do the same, otherwise a tab may keep calling code the stock server does not have.

## 10. Rollback

Choose the smallest level that fixes the problem.

**Wrapper.** `fork/deploy/rollback.sh l1|l2|forward` runs the commands of L1, L2 and the roll-forward below, in the same order, with the sed check and a timing line per step. Run it from a workstation with `PVE_HOST`, `PLANE_CTID` and `PLANE_APP_DIR` set (plus `STOCK_RELEASE` for `l2` and `FORK_N` for `forward`). `--dry-run` prints every command and changes nothing. Exit codes: 0 done, 1 usage, 2 a check failed (nothing further was run), 3 a remote command failed. It is idempotent: running `l1` twice is safe. Tests: `fork/deploy/test_rollback.sh` (stubbed ssh, pct and docker; `--self-mutate` proves the checks bite).

```
fork/deploy/rollback.sh --dry-run l1
fork/deploy/rollback.sh l1
```

`l2` also checks first that the stock image tag is in the local store (`docker image ls -q makeplane/plane-backend:$STOCK_RELEASE`) and warns when the up takes longer than 60 s. `forward` checks that the five fork services run `v1.4.2-live.$FORK_N` and deletes the L1 file only if they do. The manual commands below are the fallback and stay the reference.

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

- Keep the two most recent fork tags in the container's image store (the running one and the previous one). Remove older ones by exact tag: `docker image rm localhost/plane-fork-web:v1.4.2-live.<old>` (and `-live`, `-api`).
- Never prune stock images: no `docker image prune -a`, no `docker system prune -a`, no removal of `makeplane/*`, `postgres`, `valkey`, `rabbitmq` or `minio` images. Rollback L2 depends on them.
- Delete image archives from `$PVE_STAGING_DIR` and `$CT_STAGING_DIR` after the checksum check.

## 12. Finish

Remove the pause flag at `$PAUSE_FLAG_PATH`. Record the outcome, the measured rollback times and the fork tag now running.
