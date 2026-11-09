# Security Audit: AI-Generated Container Configurations

**Repository:** `Container-Orchestration`
**Application:** ContainerOps Dashboard
**Scope:** Compares the deliberately flawed examples in `audit/` with the production configuration at the repository root.

| Initial (educational, do not deploy) | Corrected (production) |
|---|---|
| [`audit/initial.Dockerfile`](initial.Dockerfile) | [`Dockerfile`](../Dockerfile) |
| [`audit/initial-compose.yaml`](initial-compose.yaml) | [`compose.yaml`](../compose.yaml) + [`nginx/nginx.conf`](../nginx/nginx.conf) |

> **Status of this document.** The findings below are **AI-generated audit candidates**, written by Claude (Anthropic) together with the configuration files. The student has **not yet** independently confirmed, corrected or verified them. Use the "Student Verification Log" at the end to record your own inspection, the commands you ran, and what you observed. Do not treat any row as verified until you have filled it in.
>
> The `audit/` examples are intentionally insecure. They are excluded from the Docker build context (`.dockerignore`) and must never be built or deployed.

---

## 1. Findings Summary

Severity reflects a typical small web service; adjust it if your threat model differs.

| # | Finding | Initial Problem | Risk | Correction | Verification |
|---|---|---|---|---|---|
| 1 | Non-root execution | No `USER` directive, so the container runs as root (UID 0) | Privilege escalation risk: a compromised app has root inside the container, which makes container-escape and host-mount abuse easier | Dedicated system user `appuser` (UID/GID 10001) created in the Dockerfile; `USER appuser:appgroup`; Compose also sets `user: "10001:10001"` | Docker inspection: `docker image inspect -f '{{.Config.User}}' containerops-dashboard:1.0.0` and `docker compose exec web id` |
| 2 | Layer caching | `COPY . .` runs before `npm install` | Slow rebuilds: every source edit invalidates the dependency layer and reinstalls all packages | `package.json` and `package-lock.json` are copied first and `npm ci` runs, then the source is copied | Dockerfile review, then rebuild after editing `app/public/styles.css` and check that the `npm ci` step shows `CACHED` |
| 3 | Image optimization | Single-stage build on `node:latest` (Debian) with build tools | Larger attack surface: compilers, git, vim and package managers all ship to production. Bigger image, more CVEs | Multi-stage build on pinned `node:22.23.4-alpine3.24`. The `deps` stage installs packages and the `runtime` stage copies only `node_modules` and `app/`. npm, npx, corepack and yarn are removed from the runtime | Image inspection: `docker images containerops-dashboard`, `docker history containerops-dashboard:1.0.0`, `docker run --rm --entrypoint sh containerops-dashboard:1.0.0 -c 'command -v npm'` (should print nothing) |
| 4 | Resource limits | No CPU, memory or PID limits | Resource exhaustion: one runaway replica (memory leak, fork bomb, CPU spin) can starve the host and the other replicas | `deploy.resources.limits` (web: 0.5 CPU, 128 MiB, 100 PIDs; nginx: 0.5 CPU, 64 MiB, 100 PIDs) plus `reservations` | Compose inspection: `docker compose config`, `docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.PidsLimit}}' <id>`, `docker stats --no-stream` |
| 5 | Health checks | No `HEALTHCHECK` in the image and no `healthcheck:` in Compose | Undetected failures: a hung process still looks "Up", and Nginx starts before the app is ready | `HEALTHCHECK` runs `node app/healthcheck.js` (calls `/healthz` with no curl or wget needed). Compose health checks cover web and nginx, and `depends_on: condition: service_healthy` | Runtime testing: `docker compose ps` shows `(healthy)`; `docker inspect -f '{{json .State.Health}}' <id>` |
| 6 | Restart policy | `restart: "no"` | A crashed replica stays down until someone notices | `restart: unless-stopped` on both services | Kill the Node process inside a replica (see README §20) and watch `RestartCount` increase |
| 7 | Horizontal scaling blocked | `container_name: web` and host port `3000:3000` on the app | `--scale web=3` fails: container names and host ports must be unique | No `container_name` and no host `ports:` on `web` (only `expose: 3000`). Only Nginx publishes a host port | `docker compose up -d --scale web=3` and `docker compose ps` |
| 8 | Proxy bypass / exposure | App port published directly on `0.0.0.0` | The app is reachable without the proxy, so proxy-level controls are skipped. The service is exposed to the LAN | The web service sits only on an `internal: true` network. Nginx is published on `127.0.0.1:8080` by default (`HOST_BIND`) | `docker compose ps web` (PORTS shows only `3000/tcp`, no host mapping); `docker network inspect container-orchestration_backend -f '{{.Internal}}'` |
| 9 | Static upstream / no load balancing | Nginx `proxy_pass http://web:3000` resolved once at startup | Nginx keeps stale replica IPs and never sees scaled or restarted replicas | `upstream` with `zone` and `server web:3000 resolve`, plus `resolver 127.0.0.11 valid=5s` (Docker DNS) | Scale to 4 and see 4 hostnames from `/api/instances` with no Nginx reload (the QA script does this) |
| 10 | Hard-coded secret | `ENV API_KEY=...` in the Dockerfile and Compose | Secrets persist in image layers and `docker history`, and get committed to Git | No secrets are needed. Configuration comes from env vars, `.env` is git- and docker-ignored, and only `.env.example` is committed | `docker history --no-trunc containerops-dashboard:1.0.0`, `git ls-files` (no `.env`) |
| 11 | Build-context leakage | No `.dockerignore`, so `COPY . .` copies `.git`, `.env`, `node_modules`, tests | Secrets and repo history inside the image, bigger context, slower builds | `.dockerignore` excludes `.git`, `.env*`, `node_modules`, logs, tests, `audit/`, docs | `docker run --rm --entrypoint ls containerops-dashboard:1.0.0 -la /app` |
| 12 | Non-reproducible builds | `node:latest`, `nginx:latest`, `npm install` | Builds change silently over time and can pull in breaking or vulnerable versions | Pinned base tags (`node:22.23.4-alpine3.24`, `nginxinc/nginx-unprivileged:1.30.6-alpine`), exact `express` version, `npm ci` with the lockfile | Dockerfile and Compose review; `npm ci` fails if the lockfile and `package.json` disagree |
| 13 | Excess Linux capabilities / writable FS | Default capability set, writable root filesystem, privilege escalation allowed | A compromised process can modify binaries, bind raw sockets or escalate through setuid binaries | `cap_drop: [ALL]`, `security_opt: no-new-privileges:true`, `read_only: true` with a small `tmpfs` at `/tmp` (`noexec,nosuid`) | `docker inspect -f '{{.HostConfig.CapDrop}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.SecurityOpt}}' <id>` |
| 14 | Root Nginx | `nginx:latest` master process runs as root | A larger blast radius if Nginx is compromised | `nginxinc/nginx-unprivileged` runs as UID 101 and listens on 8080, so it needs no capabilities | `docker compose exec nginx id` |
| 15 | Signal handling | Shell-form `CMD npm start` | SIGTERM goes to `sh`/`npm`, not Node. In-flight requests get cut off and shutdown waits for the 10 s kill timeout | Exec-form `CMD ["node","app/server.js"]`, `init: true` (tini), and SIGTERM/SIGINT handlers that drain connections and flip `/readyz` to 503 | `docker compose stop web` then `docker compose logs web` should show "Received SIGTERM; draining connections" |
| 16 | Code mutability | App files owned by the runtime user (or root process with write access) | An attacker could change the app code at runtime | App files owned by `root:root`, mode `644`/`755`, so the app user can read but not write. The root FS is read-only too | `docker compose exec web sh -c 'touch /app/app/x'` should fail |
| 17 | Unbounded logs | Default `json-file` logging with no rotation | Disk exhaustion on the host | `logging.options: max-size: 10m, max-file: 3` | `docker inspect -f '{{json .HostConfig.LogConfig}}' <id>` |
| 18 | Information disclosure | Express `X-Powered-By`, Nginx version banner, stack traces | Helps attackers fingerprint the versions in use | `app.disable('x-powered-by')`, `server_tokens off`, a generic 500 handler, plus security headers (CSP, `X-Content-Type-Options`, `X-Frame-Options`, ...) | `curl -sI http://localhost:8080/` |

---

## 2. Specific Changes in the Final `Dockerfile`

| Line(s) / instruction | Change | Why |
|---|---|---|
| `ARG NODE_IMAGE=node:22.23.4-alpine3.24` | Explicit, pinned Node.js 22 LTS on Alpine | Reproducible, small (musl/BusyBox), maintained LTS line |
| `FROM ... AS deps` / `FROM ... AS runtime` | Two-stage build | The runtime stage gets only the files it needs and no npm cache or build tooling |
| `COPY package.json package-lock.json ./` before source | Dependency manifests first | Docker layer cache: dependency install reruns only when the manifests change |
| `RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts` | Lockfile-exact, production-only install. Lifecycle scripts are disabled and the npm cache stays outside the layers | Reproducible, smaller image, and less supply-chain risk from install scripts |
| `RUN rm -rf .../npm .../corepack ... yarn` | Package managers removed from the runtime image | The running app never needs them, so there are fewer binaries and CVEs |
| `addgroup -S -g 10001 appgroup && adduser -S -D -H -u 10001 ...` | Dedicated system user with no home and no login shell | Least privilege. A fixed UID makes the `user:` field in Compose and the policy checks predictable |
| `COPY --from=deps --chown=root:root ...` / `COPY --chown=root:root --chmod=u=rwX,go=rX app ./app` | Files owned by root and read-only for the app user | The app can't change its own code |
| `USER appuser:appgroup` | Explicit non-root user | Required by the assignment and a container security baseline |
| `HEALTHCHECK ... CMD ["node", "app/healthcheck.js"]` | Health check uses Node's built-in `http` module | Works without curl or wget, so nothing extra has to be installed |
| `CMD ["node", "app/server.js"]` | Exec form | Node receives SIGTERM/SIGINT and shuts down gracefully |

## 3. Specific Changes in the Final `compose.yaml` / `nginx.conf`

- **Two services only:** `web` (scalable Node.js app) and `nginx` (single public entry point).
- **Scaling:** `deploy.replicas: ${WEB_REPLICAS:-3}`, no `container_name`, no host port on `web`.
- **Networks:** `frontend` (bridge, Nginx only) and `backend` (bridge, `internal: true`, both services). The web replicas have no route to the internet.
- **Hardening (both services):** `read_only`, `tmpfs` `/tmp`, `cap_drop: [ALL]`, `no-new-privileges`. Web also gets `user: "10001:10001"` and `init: true`.
- **Health:** health checks on both services, `start_period`/`start_interval` for fast startup, and Nginx `depends_on` web `service_healthy` (with `restart: true`).
- **Resources:** CPU/memory/PID limits and reservations on both services.
- **Restart:** `restart: unless-stopped`, plus `stop_grace_period: 15s`, which is longer than the app's 10 s drain timeout.
- **Logs:** rotated `json-file` logs.
- **Nginx:** `upstream web_backend { zone ...; server web:3000 resolve ...; keepalive 16; }` with `resolver 127.0.0.11 valid=5s`. Forwarded headers (`X-Forwarded-For/Proto/Host/Port`, `X-Real-IP`, `X-Request-ID`), passive failover (`proxy_next_upstream`, `max_fails`), `server_tokens off`, a 16 KiB body limit and a dedicated `/nginx-health` endpoint.

## 4. Residual Risks and Limitations (not fixed by this project)

- **No TLS.** Traffic to `localhost:8080` is plain HTTP. Production would terminate TLS at Nginx or an upstream load balancer.
- **No image vulnerability scanning or signing** is automated. Consider `docker scout cves`, Trivy or Grype, and pinning images by digest (`@sha256:...`).
- **Nginx health checking is passive only.** Open-source Nginx has no active upstream health checks. It notices a dead replica only when a request to it fails (see README "Limitations").
- **Docker Compose isn't a reconciler.** It doesn't recreate deleted containers or reschedule anything (see README §20).
- **The base images include BusyBox** (`sh`, `wget`). Distroless images would shrink the surface further, but they make the Alpine-based debugging used in this assignment harder.
- **No rate limiting** is configured. `limit_req` could be added to Nginx if the service were exposed publicly.

---

## 5. Student Verification Log (to be completed by the student)

> Fill this in yourself. Record only what you actually ran and observed.

| # | Finding | Command(s) I ran | What I observed | Confirmed? (Y/N) | Correction I made (if any) |
|---|---|---|---|---|---|
| 1 | Non-root execution | | | | |
| 2 | Layer caching | | | | |
| 3 | Image optimization | | | | |
| 4 | Resource limits | | | | |
| 5 | Health checks | | | | |
| 6 | Restart policy | | | | |
| 7 | Horizontal scaling | | | | |
| 8 | Proxy bypass / exposure | | | | |
| 9 | Static upstream | | | | |
| 10 | Hard-coded secret | | | | |
| 11 | Build-context leakage | | | | |
| 12 | Non-reproducible builds | | | | |
| 13 | Capabilities / writable FS | | | | |
| 14 | Root Nginx | | | | |
| 15 | Signal handling | | | | |
| 16 | Code mutability | | | | |
| 17 | Unbounded logs | | | | |
| 18 | Information disclosure | | | | |

**Additional issues I found that the AI did not list:**

- _(to be completed by the student)_

**Disagreements with the AI's assessment:**

- _(to be completed by the student)_
