# QA Results: Container-Orchestration

> **Template: to be completed by the student.**
> Record only results you have personally observed. Paste real command output, attach real screenshots, and mark each test PASS or FAIL based on what actually happened. Nothing in this file has been pre-filled with results.

## Test Run Information

| Field | Value |
|---|---|
| Tester | |
| Date / time | |
| Operating system | |
| Docker Engine version (`docker version --format '{{.Server.Version}}'`) | |
| Docker Compose version (`docker compose version --short`) | |
| Git commit tested (`git rev-parse --short HEAD`) | |
| Automated run command | `bash tests/qa-test.sh` |
| Automated run evidence folder (`qa-output/<timestamp>/`) | |
| Automated summary (Passed / Failed) | |

---

## 1. Image and Build Verification

| ID | Test | Command(s) executed | Expected result | Actual observation | Pass/Fail | Evidence (screenshot / log file) |
|---|---|---|---|---|---|---|
| B1 | Image builds successfully | `docker compose build` | Build completes with no errors | | | |
| B2 | Image is correctly tagged | `docker images containerops-dashboard` | `containerops-dashboard:1.0.0` listed | | | |
| B3 | Image size inspected | `docker image inspect -f '{{.Size}}' containerops-dashboard:1.0.0` | Size recorded (MB) | | | |
| B4 | Configured image user | `docker image inspect -f '{{.Config.User}}' containerops-dashboard:1.0.0` | `appuser:appgroup` | | | |
| B5 | Container process UID | `docker compose exec web sh -c 'awk "/^Uid:/{print \$2}" /proc/$(pgrep -o -x node)/status'` | `10001` (non-root) | | | |
| B6 | Layer cache reuse | Edit `app/public/styles.css`, run `docker compose build` again | `npm ci` step shows `CACHED` | | | |
| B7 | npm absent from runtime | `docker run --rm --entrypoint sh containerops-dashboard:1.0.0 -c 'command -v npm'` | No output (exit code 127) | | | |

## 2. Functional Testing (through Nginx on port 8080)

| ID | Test | Command(s) executed | Expected result | Actual observation | Pass/Fail | Evidence |
|---|---|---|---|---|---|---|
| F1 | Homepage | `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/` | `200` | | | |
| F2 | Liveness | `curl -i http://localhost:8080/healthz` | `200`, JSON `status: healthy`, hostname, timestamp | | | |
| F3 | Readiness | `curl -i http://localhost:8080/readyz` | `200`, JSON `status: ready` | | | |
| F4 | Runtime info | `curl -s http://localhost:8080/api/info` | Valid JSON with hostname, nodeVersion, uptimeSeconds, timestamp, requestCount, status | | | |
| F5 | Instance metadata | `curl -s http://localhost:8080/api/instances` | Valid JSON with `instance.hostname`, `instance.containerId`, `instance.uid` | | | |
| F6 | Dashboard assets | Open `http://localhost:8080` in a browser with DevTools > Network | `index.html`, `styles.css`, `app.js` all 200; no console errors | | | |
| F7 | Refresh button | Click **Refresh Server Data** several times | Values update; hostname may change between replicas | | | |
| F8 | Mobile layout | Browser DevTools device toolbar (for example 390 px wide) | Single-column layout, no horizontal scrolling | | | |

## 3. Orchestration Testing

| ID | Test | Command(s) executed | Expected result | Actual observation | Pass/Fail | Evidence |
|---|---|---|---|---|---|---|
| O1 | Stack starts | `docker compose up -d` | nginx + web containers created | | | |
| O2 | Scale to three | `docker compose up -d --scale web=3` then `docker compose ps` | 3 `web` containers | | | |
| O3 | All replicas healthy | `docker compose ps` | Every `web` shows `(healthy)` | | | |
| O4 | Nginx healthy and proxying | `docker compose ps nginx`; `curl http://localhost:8080/healthz` | `(healthy)`; HTTP 200 | | | |
| O5 | Load balancing | `for i in $(seq 1 9); do curl -s http://localhost:8080/api/instances \| grep -o '"hostname":"[^"]*"'; done` | Multiple distinct hostnames | | | |
| O6 | Nginx upstream log | `docker compose logs nginx \| grep upstream=` | Different `upstream=` IPs | | | |
| O7 | Crash -> automatic restart | Kill the Node process in one replica (README section 20) and then `docker inspect -f '{{.RestartCount}}' <id>` | RestartCount increases; container returns to `(healthy)` | | | |
| O8 | Availability during failure | Run the request loop from README section 20 while O7 happens | Requests keep succeeding (a single failed request during failover is possible; record it) | | | |
| O9 | `docker kill` behaviour | `docker kill <id>` and then `docker compose ps -a` | Container stays `Exited` (Docker treats it as a manual stop); `docker compose up -d` restores it | | | |
| O10 | Clean shutdown | `docker compose down` | All containers and networks removed | | | |

## 4. Screenshots / Evidence Index

| # | Description | File name / link |
|---|---|---|
| 1 | Dashboard in browser (desktop) | |
| 2 | Dashboard in browser (mobile view) | |
| 3 | `docker compose ps` showing 3 healthy replicas | |
| 4 | Load balancing (curl loop or dashboard sampler) | |
| 5 | Restart count before/after crash | |
| 6 | `qa-test.sh` summary output | |

## 5. Defects Found

| ID | Description | Severity | Steps to reproduce | Status / fix |
|---|---|---|---|---|
| | | | | |

## 6. Tester Notes

_(Observations, deviations from expected behaviour, environment-specific issues.)_
