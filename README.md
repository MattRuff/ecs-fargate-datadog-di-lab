# ECS Fargate + .NET + Datadog Dynamic Instrumentation lab

A reproducible lab for one specific customer ask:

> "We bill our customers per transaction, so we need the customer ID on every
> trace. We are not adding instrumentation code for it. The only identifier we
> have is a `tenant_id` claim inside the JWT in the bearer header — and the JWT
> has to be decoded to be useful. We don't want to maintain reference tables.
> Can APM pull it out automagically?"

The answer is yes, via a **Dynamic Instrumentation Span Tag probe** on the method
where the application already decodes the JWT. This repo gives you the
everything-else: a multi-tenant .NET 8 API on ECS Fargate with the Datadog Agent
as a sidecar, the .NET tracer and Dynamic Instrumentation pre-enabled, a
multi-tenant load generator, and Terraform to stand it all up in one command.

**The probe itself is left to you on purpose** — see
[`docs/dynamic-instrumentation.md`](docs/dynamic-instrumentation.md) for probe
targets, exact capture expressions, and the gotchas (redaction, PDBs, Remote
Configuration) that will otherwise burn ten minutes of a live customer call.

---

## What gets deployed

```
                       ┌──────────────── AWS (one VPC, 2 AZs, no NAT) ─────────────────┐
  loadgen.py           │                                                              │
  5 tenants ──HTTP──▶  │  ALB :80  ──▶  ECS Fargate service (desired_count = 2)        │
  1 JWT each           │                 ┌──────────────── task (awsvpc) ───────────┐  │
                       │                 │  app            :8080                   │  │
                       │                 │   .NET 8 minimal API                     │  │
                       │                 │   + Datadog .NET tracer (CLR profiler)   │  │
                       │                 │   + Dynamic Instrumentation enabled      │  │
                       │                 │        │ traces / metrics / RC           │  │
                       │                 │        ▼ 127.0.0.1:8126                  │  │
                       │                 │  datadog-agent  :8126 tcp / :8125 udp    │  │
                       │                 └──────────────────┬───────────────────────┘  │
                       └────────────────────────────────────┼──────────────────────────┘
                                                            ▼
                                                    Datadog (APM + Remote Config)
```

Both containers sit in the same `awsvpc` network namespace, which is why the app
talks to the Agent over `127.0.0.1` with no service discovery.

### The application

A fake settlements API — the "does something" is deliberately boring.

| Endpoint | Auth | Purpose |
| --- | --- | --- |
| `GET /health` | none | ALB health check |
| `POST /dev/token` | none | Lab stand-in for the customer's IdP. Mints an HS256 JWT with a `tenant_id` claim |
| `POST /api/v1/settlements` | Bearer | Settles a batch of line items, returns billable units and charge |
| `GET /api/v1/settlements/{id}` | Bearer | Reads back a settlement, scoped to the caller's tenant |

Five tenants on four different plans generate uneven traffic, so a per-tenant
breakdown in Datadog is immediately legible rather than five flat lines.

The code path that matters is
[`app/Auth/TenantResolver.cs`](app/Auth/TenantResolver.cs). It decodes the bearer
JWT and pulls the `tenant_id` claim into a local variable — because the app needs
the tenant to choose a price list, not because of Datadog. There is no Datadog
API call anywhere in `app/`. Grep for it:

```bash
grep -ri "datadog\|dd_trace\|SetTag" app/ --include=*.cs
```

That returns nothing, which is the point of the lab.

---

## Prerequisites

- AWS credentials for an account you can create a VPC, ALB, ECS cluster and ECR repo in
- Terraform >= 1.10 (S3-native state locking)
- Docker with buildx (the image is built `linux/amd64` regardless of your laptop's arch)
- AWS CLI v2, Python 3, curl
- A Datadog API key, in an org where **Remote Configuration is enabled**
  (Organization Settings → Remote Configuration). Dynamic Instrumentation does
  not work without it, and it is off by default in some orgs.

No local .NET SDK needed — the app is compiled inside the Docker build.

---

## AWS authentication

On a Datadog laptop this is the one step that reliably goes wrong, so it gets its
own section. `lab.sh` resolves your credentials and hands them to Terraform; if
it cannot, it tells you exactly what to run.

### The short version

```bash
aws sso login --profile sso-ese-sandbox-account-admin
```

```bash
AWS_PROFILE=sso-ese-sandbox-account-admin DD_API_KEY=<key> ./lab.sh
```

Substitute your own sandbox profile. `./lab.sh` also accepts
`--aws-profile=NAME`.

### Why bare `aws sso login` fails

```
aws: [ERROR]: An error occurred (Configuration): Missing the following required
SSO configuration values: sso_start_url, sso_region.
```

The `[default]` profile on a Datadog-managed laptop has no SSO configuration — it
carries `login_session` / `mfa_serial` and is driven by a wrapper (`aws-vault`
with an `osascript` prompt, in the profiles named `exec-*`). SSO lives in the
named profiles instead, so `aws sso login` needs `--profile`.

### Why a script can fail when your terminal works

That wrapper only refreshes the cached SSO token when **stdout is a terminal**.
The same command succeeds typed and fails piped:

```bash
aws sts get-caller-identity              # works
aws sts get-caller-identity >/dev/null   # CreateOAuth2Token ... INVALID_REQUEST
```

`lab.sh` works around this: it warms the token through a pty (`script -q
/dev/null`), retries up to three times, then exports the resolved credentials
into the environment so the Terraform AWS provider — which cannot follow the
wrapper at all — has static keys to use. Logging in properly with `--profile`
avoids the whole dance, because a valid cached token needs no refresh.

### Finding your profile among ~930 accounts

When credential resolution fails, the script prints this rather than a dead end:

```
AWS credentials could not be refreshed.

  Your [default] profile has no SSO configuration, so a bare
  `aws sso login` cannot work -- that is the error you just saw.

  Pick the account you want the lab in, log in, and pass the profile back:

    aws sso login --profile sso-sandbox-account-admin
    AWS_PROFILE=sso-sandbox-account-admin DD_API_KEY=<key> ./lab.sh

  Other accounts you have access to:
    sso-jacky-labs-account-admin  [269622523990]
    sso-cnm-sandbox-account-admin  [390198823880]
    sso-ese-sandbox-account-admin  [<account-id>]
    ...
  930 accounts available. To find one by id:
    grep -B2 'sso_account_id=<ACCOUNT_ID>' ~/.aws/config | grep '^\[profile'
  ./lab.sh also takes --aws-profile=NAME
```

A Datadog `~/.aws/config` holds on the order of **80,000 profiles across ~930
accounts**, so a flat list is useless. The output collapses to one profile per
account, prefers the `account-admin` role, ranks sandbox/ese/lab names first, and
caps at eight.

**Treat the first suggestion as a template, not an answer.** The script cannot
know which sandbox you mean, so it may lead with a different account than the one
you want — that is why the account ids are printed. Pick yours from the list.

---

## Tagging

This account runs a tag policy that alerts within minutes of an untagged resource
appearing. Every lab resource gets `ts_creator` and `ts_team` on top of the usual
`creator`, `team`, `please_keep_my_resource`, `project` and `lab_instance` — the
first set alone is not enough to satisfy the policy.

If you are not Matt, export your own before the first run:

```bash
export TS_CREATOR=you@datadoghq.com
export TS_TEAM=ese          # or: shared
```

`ts_creator` must be a full `@datadoghq.com` address and `ts_team` accepts only
`ese` or `shared`; both are validated by Terraform so a bad value fails the apply
instead of firing an alert. `lab.sh` applies the same tags to the shared state
bucket, which Terraform does not manage.

---

## Quickstart

One command. It creates the lab, or joins the one your API key already owns.

```bash
DD_API_KEY=<your-datadog-api-key> ./lab.sh
```

That does all of it: resolves AWS credentials, creates the shared state bucket if
needed, derives your instance id from your API key, detects your public IP and
puts *only* that address on the ALB, builds and pushes the .NET image, applies
~32 resources, arms a 24-hour self-destruct, and prints the URL. About 5 minutes
on a cold start.

```bash
DD_API_KEY=<key> ./lab.sh load 10     # drive multi-tenant traffic
DD_API_KEY=<key> ./lab.sh status      # url, TTL, ingress, task counts, health
DD_API_KEY=<key> ./lab.sh down        # delete everything
./lab.sh help                         # every command and flag
```

### One API key, one lab

The instance id is the first 8 hex characters of `SHA-256(your API key)`. Your
key is never written to disk by the script — it is passed to Terraform in the
environment, and it lands only in the encrypted private state bucket and in AWS
Secrets Manager.

| You do this | What happens |
| --- | --- |
| Run with your key, first time | A fresh stack, named `ddlab-<your-id>-*`, reachable from your IP |
| Run with the same key from a café | Recognises the running stack, **adds** your new IP to the ALB, leaves the TTL alone |
| A colleague runs it with *their* key | A completely separate stack, own VPC/ALB/ECR, own ingress list |
| `./lab.sh down` | That one stack and its state are removed; nobody else's is touched |

Terraform state lives in `s3://ddlab-tfstate-<account-id>/instances/<id>/`, which
is what makes "join from another machine" work at all — the state is shared, so a
second laptop finds the same stack instead of building a second one.

```bash
./lab.sh list        # every instance in the account, with TTL status
./lab.sh reap --yes  # destroy every expired instance
```

`list` and `reap` need no API key: they read small metadata files next to the
state. Handy when several SAs share a sandbox.

### Self-destruct

Every instance gets a TTL, **24 hours by default**. At the deadline a one-time
EventBridge schedule calls `ecs:UpdateService` with `DesiredCount: 0` — no
Lambda, no container, nothing that can fail to deploy, because the whole point is
that it fires after you have closed your laptop and forgotten about it.

```bash
DD_API_KEY=<key> ./lab.sh up --ttl=2h     # I need this for one demo
DD_API_KEY=<key> ./lab.sh up --ttl=72h    # POV week
DD_API_KEY=<key> ./lab.sh up --ttl=0      # no TTL; you own the cleanup
```

Re-running `up` without `--ttl` preserves whatever deadline the stack already
has, so adding an IP does not silently extend the lab's life. Running `up` *with*
a `--ttl` re-arms it, and also scales a self-destructed stack back up — an
explicit `up` is the only thing that resurrects one.

**Be clear on what the TTL does and does not do.** It stops the compute, which is
the expensive part. It leaves the ALB and VPC shell, about **$0.55/day**, until
someone runs `down` or `reap`. `./lab.sh status` says so loudly once a stack is
past its deadline. If you want the guarantee that nothing at all survives, use
`down` when you are finished — it is one command and it is the honest answer.

### Verify it by hand

```bash
URL=$(DD_API_KEY=<key> ./lab.sh url)

curl -s "$URL/health"

TOKEN=$(curl -s -X POST "$URL/dev/token" \
  -H 'Content-Type: application/json' \
  -d '{"tenantId":"acme-corp","plan":"enterprise"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')

curl -s -X POST "$URL/api/v1/settlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"batchReference":"manual-1","items":[{"sku":"api-call","quantity":12,"amountUsd":3.50}]}'
```

Decode the token at your leisure — the `tenant_id` claim is in there, and
nothing in the response or the logs exposes it to Datadog. Yet.

---

## Then: the actual demo

1. Confirm the service is reporting: **APM → Services → `settlements-api`**, env
   `fargate-lab` (`./lab.sh status` prints both).
2. Confirm the tracer is reachable by Remote Configuration: **APM → Dynamic
   Instrumentation** should list `settlements-api` as an instrumentable service.
3. Create the probes described in
   [`docs/dynamic-instrumentation.md`](docs/dynamic-instrumentation.md).
4. Search `service:settlements-api @tenant_id:acme-corp` in Trace Explorer.
5. Build the per-tenant transaction count that the customer wants to invoice from.

Step 3 is where the customer's "automagically" claim gets tested, so read the
gotchas section before you do it live.

---

## Repo layout

```
lab.sh                      the only entry point: up / status / ip / load / logs /
                            scale / down / list / reap
app/                        .NET 8 minimal API
  Auth/TenantResolver.cs      ← the probe seam: decodes the JWT, no Datadog code
  Auth/DevTokenIssuer.cs      lab-only JWT minting
  Processing/SettlementProcessor.cs   second probe target, one frame deeper
  Models/                     contracts + per-plan price list
  Dockerfile                  multi-stage build, installs the .NET tracer, keeps PDBs
terraform/
  versions.tf                 providers + mandatory default_tags
  variables.tf                everything you might want to change
  network.tf                  VPC, 2 public subnets, security groups
  alb.tf                      ALB, target group, listener
  ecr.tf                      ECR repo + source-hash image tag + build/push hook
  secrets.tf                  Secrets Manager: DD API key, JWT signing key
  iam.tf                      task execution role, task role, ECS Exec
  ecs.tf                      cluster, log groups, task definition (app + agent), service
  selfdestruct.tf             one-time EventBridge schedule → ecs:UpdateService 0
  outputs.tf                  URL, ingress list, TTL, log groups, DD_SERVICE / DD_ENV
  backend.tf                  GENERATED per instance by lab.sh; gitignored
scripts/
  build_and_push.sh           linux/amd64 build → ECR
  loadgen.py                  5-tenant traffic generator, stdlib only
docs/
  dynamic-instrumentation.md  probe targets, capture expressions, gotchas
```

Terraform is driven entirely by `lab.sh`, which passes every variable explicitly
and generates `terraform/backend.tf` for the instance you are working on. Running
bare `terraform` in that directory works, but you have to supply `instance_id`
yourself and you will be pointed at whichever instance `lab.sh` touched last.

## The Datadog configuration, in one place

Everything below lives in [`terraform/ecs.tf`](terraform/ecs.tf). It is the list
to hand a customer who asks "what do we have to change to try this?"

**App container** (the only thing the tracer needs; no code changes):

| Variable | Value | Why |
| --- | --- | --- |
| `CORECLR_ENABLE_PROFILING` | `1` | Baked into the Dockerfile. Loads the CLR profiler |
| `CORECLR_PROFILER` | `{846F5F1C-F9AE-4B07-969E-05C26BC060D8}` | Datadog's profiler CLSID |
| `CORECLR_PROFILER_PATH` | `/opt/datadog/Datadog.Trace.ClrProfiler.Native.so` | From the `datadog-dotnet-apm` deb |
| `DD_DOTNET_TRACER_HOME` | `/opt/datadog` | |
| `DD_SERVICE` / `DD_ENV` / `DD_VERSION` | from tfvars | Probes are scoped by these |
| `DD_AGENT_HOST` / `DD_TRACE_AGENT_PORT` | `127.0.0.1` / `8126` | Sidecar over the shared netns |
| `DD_DYNAMIC_INSTRUMENTATION_ENABLED` | `true` | **The one that matters** |
| `DD_REMOTE_CONFIGURATION_ENABLED` | `true` | How probes reach the process |
| `DD_SYMBOL_DATABASE_UPLOAD_ENABLED` | `true` | Makes the probe UI autocomplete |
| `DD_LOGS_INJECTION`, `DD_RUNTIME_METRICS_ENABLED`, `DD_TRACE_SAMPLE_RATE` | on / on / `1` | Lab-friendly defaults |

**Agent sidecar:**

| Variable | Value |
| --- | --- |
| `DD_API_KEY` | from Secrets Manager |
| `DD_SITE` | from tfvars |
| `ECS_FARGATE` | `true` |
| `DD_APM_ENABLED`, `DD_APM_NON_LOCAL_TRAFFIC` | `true`, `true` |
| `DD_REMOTE_CONFIGURATION_ENABLED` | `true` |
| `DD_DOGSTATSD_NON_LOCAL_TRAFFIC` | `true` |

Pinned versions: .NET tracer `3.54.0` (Dynamic Instrumentation needs 2.54+, or
3.29+ for in-app enablement), Agent `public.ecr.aws/datadog/agent:7` (needs
7.49+). Both are terraform variables.

---

## Network access

Two security groups, and the ALB one is deliberately narrow:

| Security group | Ingress | Source |
| --- | --- | --- |
| `<project>-alb` | TCP 80 | `var.allowed_ingress_cidrs` — your address only |
| `<project>-task` | TCP 8080 | the ALB security group, by group id (never a CIDR) |

Nothing reaches the Fargate tasks except the load balancer, and nothing reaches
the load balancer except the CIDRs you name. `allowed_ingress_cidrs` is a
required variable with three validations: non-empty, valid IPv4 CIDRs, and no
`/0`. `lab.sh` always supplies it from your detected address. That last one exists because leaving a lab ALB open to the internet is
both against this account's rules and the kind of thing that survives in a
copy-pasted repo for years.

`lab.sh` detects your public IP on every run and injects it, so ingress is never
something you have to think about:

```bash
DD_API_KEY=<key> ./lab.sh ip              # add this machine's address
DD_API_KEY=<key> ./lab.sh ip --replace-ip # drop every other address, keep mine
DD_API_KEY=<key> ./lab.sh status          # what is on the list right now
```

`up` does the same union automatically, which is the whole "run it from a new
location and it just works" story. The list is capped at 25 entries, oldest
dropped first, so a well-travelled lab does not accumulate a hundred stale /32s.
`ip` is a targeted security-group apply — a few seconds, no task churn, no
rebuild.

Egress is open (`0.0.0.0/0`) on both groups, because the tasks have to reach ECR
and the Datadog intake. See the teardown section for why there is no NAT Gateway.

---

## Cost and teardown

Roughly **$1.50–$2.50/day** per instance with the default 2 tasks: ALB
(~$0.55/day) plus two 1 vCPU / 2 GB Fargate tasks. There is deliberately no NAT
Gateway — tasks run in public subnets with public IPs so they can reach ECR and
the Datadog intake. That saves ~$32/mo and is the single thing in this repo you
should *not* copy into a production reference architecture.

Three levels of cleanup, cheapest effort first:

| Command | Effect |
| --- | --- |
| *(nothing — the TTL fires)* | Tasks scale to 0 at the deadline. Leaves the ~$0.55/day ALB shell |
| `./lab.sh down` | Destroys that instance completely and deletes its state |
| `./lab.sh reap --yes` | Destroys **every** expired instance in the account |

`down` removes the ECR repo (`force_delete = true`) and both secrets
(`recovery_window_in_days = 0`, so no 7-day zombie), then deletes the instance's
state prefix from S3. The only thing left behind is the shared state bucket
itself, which holds nothing and costs nothing.

Every resource carries `creator`, `please_keep_my_resource`, `team`, `project`,
`lab_instance`, `ts_creator` and `ts_team` via provider `default_tags`, plus
`expires_at` when the instance has a TTL. The state bucket is tagged the same way
by `lab.sh`, since Terraform does not manage it.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `no usable AWS credentials` | The script prints candidate profiles. `aws sso login --profile <name>`, then re-run with `AWS_PROFILE=<name>` |
| `aws sso login` says "Missing required SSO configuration values" | You ran it without `--profile`. The `[default]` profile has no SSO config; pass a real one |
| Datadog rejected that API key | Wrong key, or wrong `--dd-site`. Bypass the check with `--skip-validate` |
| A second stack appeared instead of joining | Different API key, or a different AWS account — instance identity is `SHA-256(key)` scoped to one account's state bucket |
| Lab vanished overnight | The 24h TTL fired and scaled it to zero. `./lab.sh up` brings it back; `--ttl=72h` to give yourself longer |
| Tag policy alert on a lab resource | Set `TS_CREATOR` / `TS_TEAM` before the first run; `ts_team` accepts `ese` or `shared` |
| ALB times out / hangs from your laptop | Your public IP changed. `./lab.sh ip` adds your new address in a few seconds |
| `terraform apply` fails on `allowed_ingress_cidrs` | Only when driving Terraform by hand: it is required, must be valid IPv4 CIDRs, and cannot be `/0`. `lab.sh` fills it in for you |
| Tasks cycle, `CannotPullContainerError` | Image push failed. Re-run `scripts/build_and_push.sh` by hand and read the output |
| Tasks start, ALB returns 503 | Health check grace period; wait ~60s. If it persists, `./lab.sh logs` — usually `Jwt:SigningKey is not configured`, meaning the execution role can't read the secret |
| App container never starts | It `dependsOn` the Agent being `HEALTHY`. `./lab.sh logs agent` — an invalid `DD_API_KEY` is the usual culprit |
| Service in Datadog but not in Dynamic Instrumentation | Remote Configuration is off at the org level, or the API key predates RC. Check Organization Settings → Remote Configuration |
| Probe created but "not installed" | `DD_REMOTE_CONFIGURATION_ENABLED` missing on the *tracer*, or service/env/version mismatch |
| Line probe won't bind to a line | PDBs got stripped from the image. See `DebugType` in `app/MultiTenantApi.csproj` |
| Captured value shows as redacted | Expected for identifiers like `bearerToken`. Set `dd_di_redaction_excluded_identifiers` in tfvars |
| Build fails on Apple Silicon | `docker buildx` must be available; the build forces `--platform linux/amd64` |

---

## Adapting this for a different customer

- **Their own app instead of the sample**: replace `app/`, keep the Dockerfile's
  tracer install block and the `DebugType=portable` csproj settings, keep every
  `DD_*` variable in `ecs.tf`. Those are the whole integration.
- **Real IdP instead of `/dev/token`**: set `Lab__EnableDevTokenEndpoint` to
  `false` in `ecs.tf` and point `Jwt:Issuer` / `Jwt:Audience` at the real issuer
  with JWKS validation. The probe seam in `TenantResolver` does not change —
  which is the reassuring part for the customer.
- **A different claim name**: `TenantResolver.TenantIdClaim`. In a customer's own
  code, this is whatever local variable their auth layer already assigns.
- **Tighter ingress still**: put the ALB behind an internal scheme plus a VPN,
  or add an HTTPS listener with ACM. `allowed_ingress_cidrs` accepts a list, so a
  corporate egress range works as well as a single `/32`.
- **Private subnets**: add a NAT Gateway (or VPC endpoints for ECR, S3, Logs and
  Secrets Manager) and flip `assign_public_ip` to `false`.
