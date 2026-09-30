<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Running the fork tests natively (no podman)

`node-tests.sh` and `api-tests.sh` need podman. On a plain Linux VM (root or a sudo-capable user, no
container runtime required) use the native variants instead. They run the same steps, the same
pytest paths and the same environment.

| Podman                    | Native                          |
| ------------------------- | ------------------------------- |
| `fork/test/node-tests.sh` | `fork/test/cloud-node-tests.sh` |
| `fork/test/api-tests.sh`  | `fork/test/cloud-api-tests.sh`  |

All paths below are relative to the repository root. The scripts locate the tree from their own
location; override with `PLANE_SRC`. Logs go to `OUT_DIR` (default `${TMPDIR:-/tmp}/plane-cloud-tests`).

## Node

Needs node 22.18 or newer with corepack (no global pnpm). The script enables the pnpm pinned in the
root `package.json` `packageManager` field into `$OUT_DIR/bin` (no root needed), puts that on `PATH`
so turbo finds the same pnpm, and fails if the versions differ.

```
fork/test/cloud-node-tests.sh all          # install, build-libs, live-test, live-types, web-types, web-lint, live-events
fork/test/cloud-node-tests.sh live-test    # one step (needs install and build-libs to have run once)
fork/test/cloud-node-tests.sh live-test live-types   # several steps
```

Step names match `node-tests.sh` (`install`, `build-libs`, `live-test`, `live-types`, `web-types`,
`web-lint`, `all`, `sh '<cmd>'`), plus `live-events` (`sh fork/test/live-events/run.sh`, which needs
no install). Every step prints `CLOUDNODE step=<name> rc=<code> wall_s=<n> <result>` and the lines are
repeated as a summary at the end. `all` runs every step even after a failure (except after a failed
install) and the exit code is the first non-zero step code. An unknown step exits 2.

`build-libs` must run before `live-test` and `web-types` (see section 8 of `fork/SPIKE.md`).

## API

```
fork/test/cloud-api-tests.sh                                   # services from apt, plane/tests/unit plane/tests/contract
fork/test/cloud-api-tests.sh --services docker                 # services in docker run containers
fork/test/cloud-api-tests.sh --services external               # services already running, only probed
fork/test/cloud-api-tests.sh plane/tests/contract/api/test_pages.py   # extra pytest args replace the default paths
fork/test/cloud-api-tests.sh --services apt -- -m unit         # "--" ends the script options
```

`--services` (or `PLANE_TEST_SERVICES`):

- `apt`: postgresql, redis-server and rabbitmq-server from the distro. Missing packages (and
  `libpq-dev`, needed because `psycopg-c` compiles) are installed with `apt-get` when running as root.
  The script starts the postgres cluster, redis and rabbitmq if their ports are closed, then creates
  the `plane` role (SUPERUSER, the tests create a test database), the `plane` database, and the
  rabbitmq vhost, user and permissions, each only if missing. Services it started are left running.
- `docker`: containers `plane-cloudtest-db`, `-redis`, `-mq`, published on 127.0.0.1 only, on tmpfs.
  Images: `PG_IMAGE` (postgres 16 alpine), `REDIS_IMAGE` (valkey 7.2.11 alpine, as in the pod),
  `MQ_IMAGE` (rabbitmq 3.13.6 alpine, as in the pod). Containers the run created are removed at exit
  unless `--keep`; existing containers are reused or restarted.
- `external`: nothing is started; the script fails if a service does not answer.

In every mode a service that already answers on its port is reused, so re-running is safe.
Ports, hosts and the throwaway credentials are overridable (`DB_PORT`, `REDIS_PORT`, `MQ_PORT`,
`DB_HOST`, ... see the header of the script); the defaults equal `api-tests.sh` (`plane`/`plane`).

The venv (`PLANE_VENV`, default under `${XDG_CACHE_HOME:-$HOME/.cache}/plane-cloud-tests`) is created
with python 3.12 (`PYTHON` to override; `uv` is used when present, else `python -m venv`) and reused.
`apps/api/requirements/test.txt` is installed again only when a requirements file changed.
minio is not started: the unit and contract suites mock S3, as in `api-tests.sh`.

The script prints `CLOUDAPI services=<mode> pytest_rc=<code>` and the pytest result line, and exits
with pytest's exit code (2 for a setup failure).

## Differences from the podman pod

|              | podman pod (`api-tests.sh`)                       | native reference run                                                  |
| ------------ | ------------------------------------------------- | --------------------------------------------------------------------- |
| postgres     | 15.7                                              | 16.x (Ubuntu 24.04 apt)                                               |
| redis        | valkey 7.2.11                                     | redis 7.0.15 (apt); `--services docker` defaults to valkey 7.2.11     |
| rabbitmq     | 3.13.6                                            | distro package (apt); 3.13.6 with `--services docker`                 |
| python       | 3.12 (backend image)                              | 3.12                                                                  |
| dependencies | image plus `pip install -r requirements/test.txt` | fresh venv with `requirements/test.txt`; `psycopg-c` compiled locally |
| node         | node:22-alpine                                    | host node 22.x (glibc)                                                |

Nothing in the suites depends on those differences, but a failure that appears in only one place is
worth checking against them first.

## Reference run (all steps passed)

Ubuntu 24.04, node 22, pnpm 11.3.0, python 3.12, on `live-updates/v1.4.2`.

| Step                                         | Result                                 |
| -------------------------------------------- | -------------------------------------- |
| live vitest (`live-test`)                    | 8 files, 147 tests passed              |
| `live-types`, `web-types`                    | 0 errors                               |
| `web-lint`                                   | 0 errors, 780 warnings                 |
| live-events                                  | 32 pass, 0 fail                        |
| API `plane/tests/unit plane/tests/contract`  | 747 passed, 0 failed (about 4 minutes) |
| API `plane/tests/contract/api/test_pages.py` | 97 passed                              |

`fork/test/cloud-tests.selftest.sh` checks the argument parsing and exit codes of both scripts with
stubs (no node, database or network needed).
