<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Deploy runbook: live updates and pages API

Every host-specific value is a variable supplied by the operator at run time. Nothing on this page is a real hostname, address, container number or path.

| Variable            | Meaning                                                                                      |
| ------------------- | -------------------------------------------------------------------------------------------- |
| `PVE_HOST`          | ssh target of the hypervisor                                                                 |
| `PLANE_CTID`        | container id of the Plane container on the hypervisor                                        |
| `PLANE_APP_DIR`     | directory in the container holding `docker-compose.yaml` and `plane.env`                     |
| `PAUSE_FLAG_PATH`   | path of the flag file that pauses automated changes (operator supplied)                      |
| `PVE_STAGING_DIR`   | scratch directory on the hypervisor for the image archive                                    |
| `CT_STAGING_DIR`    | scratch directory in the container for the image archive                                     |
| `BUILD_HOST`        | machine where the images were built with podman                                              |
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

On `$BUILD_HOST` (podman), after the images are built and pass `fork/test/live-smoke.sh`:

```
podman save -m --format docker-archive -o images.tar \
  localhost/plane-fork-web:v1.4.2-live.$FORK_N \
  localhost/plane-fork-live:v1.4.2-live.$FORK_N \
  localhost/plane-fork-api:v1.4.2-live.$FORK_N
sha256sum images.tar
scp images.tar "$PVE_HOST:$PVE_STAGING_DIR/"
```

On the hypervisor, then in the container:

```
ssh "$PVE_HOST" "sha256sum $PVE_STAGING_DIR/images.tar"
ssh "$PVE_HOST" "pct push $PLANE_CTID $PVE_STAGING_DIR/images.tar $CT_STAGING_DIR/images.tar"
ssh "$PVE_HOST" "pct exec $PLANE_CTID -- sha256sum $CT_STAGING_DIR/images.tar"
ssh "$PVE_HOST" "pct exec $PLANE_CTID -- docker load -i $CT_STAGING_DIR/images.tar"
```

The three checksums must be identical. `docker load` prints the three `localhost/plane-fork-*:v1.4.2-live.$FORK_N` names; confirm with `docker image ls 'localhost/plane-fork-*'`. Delete both archive copies afterwards.

## 4. Install the override

Copy `fork/deploy/docker-compose.override.yaml` into `$PLANE_APP_DIR` (`pct push`, same as above) and add these keys to `plane.env` (set values yourself; do not paste secrets anywhere):

```
FORK_N=<number>
LIVE_EVENTS_ALLOWED_ORIGINS=<PUBLIC_URL>,<LAN_URL>
```

`WEB_URL` must already be defined in `plane.env` (see inspection). `CORS_ALLOWED_ORIGINS` stays as it is; the override never passes it into live.

## 5. Env key-name check (names only)

Before applying, validate quietly:

```
$C config -q && echo config-ok
```

After step 6, check the running containers. These print names, never values:

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

## 6. Apply and image-tag check

```
$C up -d
$C ps --format '{{.Service}} {{.Image}}'
```

Expected images: `web`, `live`, `api`, `worker`, `beat-worker` all `localhost/plane-fork-*:v1.4.2-live.$FORK_N` (web -> `plane-fork-web`, live -> `plane-fork-live`, the other three -> `plane-fork-api`). Every other service keeps its stock image. Exactly one `live` container must be running. If any of the five shows a stock image, the stack was started without the override (for example through `setup.sh`): rerun `$C up -d`.

Wait for `api` to be healthy: `$C logs --tail 30 api`.

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

Duplicate a page in the UI: it must still work and the copy must open normally (the worker has no `LIVE_BASE_URL`, so the live sync stays off).

## 8. Rehearsal of rollback L1 and L2, then roll forward

Targets are estimates; record the measured times here.

| Step | Target | Measured |
| ---- | ------ | -------- |
| L1   | 1 to 2 min |      |
| L2   | 2 to 4 min |      |
| Roll forward | 1 to 2 min |  |

## 9. Hard reload

The web bundle changed. Tabs opened before the deploy keep running the old code (no live updates) until reloaded. Tell users to hard-reload once (Ctrl+Shift+R, or Cmd+Shift+R). After L2 or L3 do the same, otherwise a tab may keep calling code the stock server does not have.

## 10. Rollback

Choose the smallest level that fixes the problem.

**L1: both flags off (about 1 to 2 min).** Keeps the fork images, turns the behaviour off. Live events stop (the socket closes with 4404) and the pages API answers 404.

```
sed -e 's/LIVE_EVENTS_ENABLED: "1"/LIVE_EVENTS_ENABLED: "0"/' \
    -e 's/PAGES_API_ENABLED: "1"/PAGES_API_ENABLED: "0"/' \
    docker-compose.override.yaml > docker-compose.override.l1.yaml
docker compose -f docker-compose.yaml -f docker-compose.override.l1.yaml --env-file plane.env up -d api worker live
```

Roll forward: rerun step 6 with the normal override.

**L2: stock images (about 2 to 4 min).** Run the stack from the upstream file alone. The stock images `makeplane/*` are still in the local image store because they are never pruned.

```
APP_RELEASE=v1.4.2 docker compose -f docker-compose.yaml --env-file plane.env up -d
docker compose -f docker-compose.yaml --env-file plane.env ps --format '{{.Service}} {{.Image}}'
```

Use the release tag that was running before (see the "Image line" rows in the inspection table). Then hard-reload (step 9). Do not use `setup.sh` for this either.

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
