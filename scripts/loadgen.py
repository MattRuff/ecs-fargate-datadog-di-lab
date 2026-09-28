#!/usr/bin/env python3
"""
Multi-tenant load generator for the ECS Fargate Dynamic Instrumentation lab.

Mints a JWT per tenant from the app's lab token endpoint, then drives
POST /api/v1/settlements with a bearer token per request. Every tenant gets a
different plan and a different request rate so that, once a probe is capturing
the tenant id, the per-tenant breakdown in Datadog is visibly uneven.

Stdlib only.

    ./scripts/loadgen.sh http://<alb-dns> 10        # run for 10 minutes
    ./scripts/loadgen.sh http://<alb-dns> 1         # quick smoke test
"""

import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter

# tenant id, plan, relative weight (higher = more traffic)
TENANTS = [
    ("acme-corp", "enterprise", 5),
    ("globex", "business", 3),
    ("initech", "standard", 2),
    ("umbrella-health", "enterprise", 4),
    ("hooli", "free", 1),
]

SKUS = ["api-call", "batch-row", "doc-render", "webhook-delivery", "export-gb"]

counts = Counter()
counts_lock = threading.Lock()


def post(url, payload, token=None, timeout=20):
    data = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read() or b"{}")


def mint_token(base, tenant_id, plan):
    _, body = post(
        f"{base}/dev/token",
        {"tenantId": tenant_id, "plan": plan, "ttlMinutes": 1440},
    )
    return body["accessToken"]


def batch_payload(tenant_id):
    items = [
        {
            "sku": random.choice(SKUS),
            "quantity": random.randint(1, 40),
            "amountUsd": round(random.uniform(0.5, 90.0), 2),
        }
        for _ in range(random.randint(1, 6))
    ]
    return {"batchReference": f"{tenant_id}-{int(time.time())}-{random.randint(100, 999)}",
            "items": items}


def drive(base, tenant_id, token, weight, deadline):
    url = f"{base}/api/v1/settlements"
    while time.time() < deadline:
        try:
            status, _ = post(url, batch_payload(tenant_id), token=token)
            outcome = str(status)
        except urllib.error.HTTPError as e:
            outcome = f"{e.code}"
        except Exception as e:  # noqa: BLE001 - lab tool, any failure is just noise
            outcome = type(e).__name__
        with counts_lock:
            counts[(tenant_id, outcome)] += 1
        time.sleep(random.uniform(0.2, 1.5) / weight)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    base = sys.argv[1].rstrip("/")
    minutes = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
    deadline = time.time() + minutes * 60

    print(f"==> target {base}")
    with urllib.request.urlopen(f"{base}/health", timeout=15) as r:
        print(f"==> health: {r.status} {r.read().decode()}")

    tokens = {}
    for tenant_id, plan, _ in TENANTS:
        tokens[tenant_id] = mint_token(base, tenant_id, plan)
        print(f"==> minted token for {tenant_id} ({plan})")

    print(f"==> driving traffic for {minutes} minute(s); ctrl-c to stop early")
    threads = [
        threading.Thread(
            target=drive,
            args=(base, tenant_id, tokens[tenant_id], weight, deadline),
            daemon=True,
        )
        for tenant_id, _, weight in TENANTS
    ]
    for t in threads:
        t.start()

    try:
        while any(t.is_alive() for t in threads):
            time.sleep(5)
            with counts_lock:
                total = sum(counts.values())
            print(f"    {total} requests sent", end="\r", flush=True)
    except KeyboardInterrupt:
        print("\n==> stopping")

    print("\n==> results (tenant, http status) -> count")
    with counts_lock:
        for (tenant_id, outcome), n in sorted(counts.items()):
            print(f"    {tenant_id:18s} {outcome:12s} {n}")


if __name__ == "__main__":
    main()
