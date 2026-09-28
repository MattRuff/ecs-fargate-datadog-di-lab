# Getting `tenant_id` onto spans without touching the code

This is the part of the lab that answers the customer's actual question. The
application is already deployed and traced; nothing below requires a rebuild, a
redeploy, or a single line of Datadog SDK code.

## The customer's constraints, restated

| Constraint | What it rules out |
| --- | --- |
| Bill per transaction, per customer | Needs a tenant dimension on every request span |
| No code instrumentation | Rules out `Tracer.Instance.ActiveScope.Span.SetTag(...)`, middleware, `DD_TAGS` |
| Only identifier is a `tenant_id` claim inside the bearer JWT | Rules out `DD_TRACE_HEADER_TAGS` — that captures the raw header, and the raw header is a signed blob |
| JWT must be decoded to be useful, no reference tables | Rules out mapping an opaque id to a customer out-of-band |

What is left is: the decoded value already exists in process memory, inside a
local variable, for a few microseconds per request. A **Span Tag probe** reads
that local at runtime and appends it to the span. That is the whole trick.

## Where the value lives in this app

[`app/Auth/TenantResolver.cs`](../app/Auth/TenantResolver.cs):

```csharp
public TenantContext Resolve(HttpRequest request)
{
    string authorizationHeader = request.Headers.Authorization.ToString();
    string bearerToken = ExtractBearerToken(authorizationHeader);

    JwtSecurityToken decodedJwt = _handler.ReadJwtToken(bearerToken);

    string? tenantId = ClaimValue(decodedJwt, TenantIdClaim);   // <-- the prize
    ...
    TenantContext tenant = new(TenantId: tenantId, Plan: plan, ...);
    return tenant;
}
```

Note what this file is *not*: it has no Datadog reference, no `using Datadog.*`,
no span API. The app decodes the JWT because it needs the tenant to pick a price
list. That is ordinary application code, and it is exactly the situation the
customer described.

Two probe targets, in order of preference:

| Target | Method | Capture | Why |
| --- | --- | --- | --- |
| **A (recommended)** | `MultiTenantApi.Auth.TenantResolver.Resolve` | local `tenantId`, or return value `TenantContext.TenantId` | Runs once per request, early, on the same thread as the web span |
| **B** | `MultiTenantApi.Processing.SettlementProcessor.SettleAsync` | argument `tenant.TenantId` | Proves a probe on business logic one frame deeper still tags the entry span. Good for the "it works anywhere in the call path" demo |

Target A as a **line probe** is even tighter: put it on the line immediately
after `tenantId` is assigned, so the local is guaranteed populated.

## What to build in the Datadog UI

Under **APM → Dynamic Instrumentation → Create Probe**, select service
`settlements-api` and env `fargate-lab` (`./lab.sh status` prints both).

1. **Span Tag probe** — the billing dimension
   - Where: `TenantResolver.Resolve`
   - Tag name: `tenant_id`
   - Value: `tenantId`
   - Target: service entry span (so the tag lands on the `aspnet_core.request`
     span that Trace Explorer and span-based metrics query)

   Then in Trace Explorer: `service:settlements-api @tenant_id:acme-corp`.

2. **Metric probe** — the invoice line
   - Where: same method
   - Type: `count`, metric name `settlements.transactions`
   - Tags: `tenant_id` from `tenantId`

   This gives a metric you can sum per tenant with no span retention
   dependency, which matters if the customer only samples a fraction of traces.

3. Optional: once the span tag exists, create a **span-based metric** from it
   (`APM → Metrics`) grouped by `tenant_id`. That is usually the more durable
   billing artifact than the metric probe, because it survives probe lifecycle
   changes.

## Gotchas that will bite in a customer demo

**Redaction.** Dynamic Instrumentation redacts values whose *identifier name*
looks sensitive — `password`, `accessToken`, and friends. In this app,
`bearerToken` and `decodedJwt` are likely to be redacted, while `tenantId`,
`tenant`, and `plan` are not. This is why target A captures `tenantId` and not
the token. If you deliberately want to probe the raw token, set:

```bash
DD_API_KEY=<key> ./lab.sh up --redact-exclude=bearerToken,decodedJwt
```

The counterpart knobs are `DD_DYNAMIC_INSTRUMENTATION_REDACTED_IDENTIFIERS` and
`DD_DYNAMIC_INSTRUMENTATION_REDACTED_TYPES`. Worth showing a customer: the
default is to protect them from accidentally exfiltrating a credential into
Datadog, which is the right default for a JWT.

**Probes are scoped by service + env + version.** If `DD_VERSION` changes on a
redeploy, re-check that the probe is still active. `./lab.sh status` prints the
service and env for the instance you are pointed at.

**Several instances, several services.** Every lab instance uses the same
`DD_SERVICE` (`settlements-api`) by default, so if two SAs point their labs at
the same Datadog org their spans land in one service. Give yours its own env —
`./lab.sh up --ttl=24h` then override `dd_env` in Terraform, or just agree on
envs — before you go hunting for someone else's traces.

**Remote Configuration has to be on in three places.** The org (Organization
Settings → Remote Configuration), the Agent
(`DD_REMOTE_CONFIGURATION_ENABLED=true`, set in `terraform/ecs.tf`), and the
tracer (same variable, also set). If the probe shows "not installed", this is
almost always why — check the Agent sidecar logs first.

**PDBs must ship in the image.** `app/MultiTenantApi.csproj` pins
`DebugType=portable` and the Dockerfile publishes without stripping symbols.
Line probes cannot bind without them. If you swap in a customer's Dockerfile and
line probes stop resolving, check this first.

**Symbol database.** `DD_SYMBOL_DATABASE_UPLOAD_ENABLED=true` is what makes the
UI autocomplete types and methods instead of asking you to type fully-qualified
names from memory. Not required, very much wanted in a live demo.

**Probes are not free and not unlimited.** Each probe is rate-limited by the
tracer, and a probe on a hot path adds per-invocation cost. For the billing use
case, the honest framing to a customer is: use a Span Tag probe to *establish*
the dimension and prove the value, then decide whether the permanent answer is
the probe, a span-based metric derived from it, or eventually a three-line
middleware. Dynamic Instrumentation removes the deploy from the loop; it is not
a promise that the tag is free forever.

## Reference

- Dynamic Instrumentation overview: https://docs.datadoghq.com/dynamic_instrumentation/
- Probe types and expression language: https://docs.datadoghq.com/dynamic_instrumentation/expression-language/
- Sensitive data scrubbing: https://docs.datadoghq.com/dynamic_instrumentation/sensitive-data-scrubbing/
- .NET setup: https://docs.datadoghq.com/dynamic_instrumentation/enabling/dotnet/
