# =============================================================================
#  !!! INTENTIONALLY INSECURE EDUCATIONAL EXAMPLE - DO NOT BUILD OR DEPLOY !!!
# =============================================================================
#  Repository: Container-Orchestration  (audit/initial.Dockerfile)
#
#  This file represents a plausible *initial* AI-generated Dockerfile. It is
#  kept ONLY so that it can be compared against the production ../Dockerfile
#  in audit/SECURITY_AUDIT.md. It contains deliberate anti-patterns:
#
#   [A1] Floating, non-Alpine base tag ("node:latest")  -> unpinned, large image
#   [A2] Single-stage build                             -> build tooling ships to prod
#   [A3] COPY . . before npm install                    -> cache busted on every edit
#   [A4] npm install (not npm ci), dev deps included    -> non-reproducible, bigger
#   [A5] Unnecessary OS packages (curl, git, vim, ...)  -> larger attack surface
#   [A6] Runs as root (no USER directive)               -> privilege escalation risk
#   [A7] Whole build context copied (incl. .env, .git)  -> secret leakage risk
#   [A8] Hard-coded "secret" in ENV                     -> secret baked into layers
#   [A9] No HEALTHCHECK                                 -> failures go undetected
#   [A10] Shell-form CMD via npm                        -> signals not delivered to node
#
#  The value below is a FAKE placeholder for teaching purposes only.
# =============================================================================

FROM node:latest

WORKDIR /usr/src/app

# [A5] Debug/build tools that the running app never needs.
RUN apt-get update && apt-get install -y curl git vim python3 build-essential

# [A3][A7] Copy everything (source, .git, .env, tests...) before installing deps.
COPY . .

# [A4] Non-deterministic install, including devDependencies.
RUN npm install

# [A8] Never do this: secrets end up in the image history.
ENV API_KEY="fake-example-key-do-not-use"
ENV NODE_ENV=development

EXPOSE 3000

# [A6] No USER directive -> container runs as root (UID 0).
# [A9] No HEALTHCHECK.
# [A10] Shell form; npm becomes PID 1's child and SIGTERM handling is unreliable.
CMD npm start
