#!/usr/bin/env bash
#
# lab.sh -- one command to stand up, share, and shred the ECS Fargate +
#           Datadog Dynamic Instrumentation lab.
#
#   DD_API_KEY=xxxxxxxx ./lab.sh                 # create (or join) your lab, 24h TTL
#   DD_API_KEY=xxxxxxxx ./lab.sh                 # run again elsewhere: adds your new IP
#   DD_API_KEY=xxxxxxxx ./lab.sh down            # delete everything
#   ./lab.sh list                                # every lab instance in this account
#   ./lab.sh reap --yes                          # destroy expired instances
#
# One Datadog API key == one lab instance. The instance id is a SHA-256 prefix of
# the key, so the same key always lands on the same stack (from any machine, via
# shared S3 state) and a different key gets its own independent stack.
#
set -euo pipefail

VERSION="1.1.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform"
STATE_PREFIX="instances"
MAX_CIDRS=25
DEFAULT_TTL="24h"

# Account tag policy. Override with TS_CREATOR / TS_TEAM (ts_team: ese | shared)
# if you are not Matt -- otherwise your resources will trip the tag alert.
TS_CREATOR="${TS_CREATOR:-matthew.ruyffelaert@datadoghq.com}"
TS_TEAM="${TS_TEAM:-ese}"

export AWS_PAGER=""

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; BLU=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; RST=""
fi

step() { printf '%s==>%s %s\n' "$BLU$BOLD" "$RST$BOLD" "$*$RST"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%s!!%s  %s\n' "$YEL$BOLD" "$RST$YEL" "$*$RST" >&2; }
die()  { printf '%sxx%s  %s\n' "$RED$BOLD" "$RST$RED" "$*$RST" >&2; exit 1; }

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH${2:+ ($2)}"
}

preflight() {
  local want_docker="${1:-no}"
  need_cmd terraform "https://developer.hashicorp.com/terraform/install"
  need_cmd aws "AWS CLI v2"
  need_cmd python3
  need_cmd curl

  local tf_version
  tf_version="$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "0.0.0")"
  python3 - "$tf_version" <<'PY' || die "terraform >= 1.10 required (S3 state locking); found $tf_version"
import sys
parts = [int(x) for x in sys.argv[1].split("-")[0].split(".")[:3]]
sys.exit(0 if tuple(parts) >= (1, 10, 0) else 1)
PY

  if [[ "$want_docker" == "docker" ]]; then
    need_cmd docker
    docker info >/dev/null 2>&1 || die "the Docker daemon is not running (start Docker Desktop, then retry)"
  fi
}

# When credential resolution fails, say something useful. A bare `aws sso login`
# is a dead end if the default profile carries no SSO configuration, which is the
# common case on a machine where a wrapper (aws-vault and friends) manages it.
suggest_sso_profiles() {
  local cfg="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [[ -f "$cfg" ]] || return 0

  printf '\n%sAWS credentials could not be refreshed.%s\n\n' "$YEL$BOLD" "$RST"

  if [[ -n "${AWS_PROFILE:-}" ]]; then
    printf '  Profile in use: %s%s%s\n\n' "$BOLD" "$AWS_PROFILE" "$RST"
    printf '  Log in, then re-run this command:\n'
    printf '    %saws sso login --profile %s%s\n\n' "$BOLD" "$AWS_PROFILE" "$RST"
    return 0
  fi

  python3 - "$cfg" <<'PY'
import re, sys

cfg = open(sys.argv[1], errors="replace").read()
default_has_sso = False
by_account = {}

for block in re.split(r"^\[", cfg, flags=re.M):
    head, _, body = block.partition("]")
    name = head.strip()
    if name == "default":
        default_has_sso = "sso_start_url" in body
        continue
    if not name.startswith("profile "):
        continue
    if "sso_start_url" not in body or "sso_account_id" not in body:
        continue
    profile = name[len("profile "):].strip()
    acct = re.search(r"sso_account_id\s*=\s*(\S+)", body)
    role = re.search(r"sso_role_name\s*=\s*(\S+)", body)
    acct = acct.group(1) if acct else "?"
    role = role.group(1) if role else ""
    # One entry per account, preferring the broadest role, so the list shows
    # accounts rather than eighty roles inside the same one.
    rank = (0 if role == "account-admin" else 1 if "admin" in role else 2, len(profile))
    cur = by_account.get(acct)
    if cur is None or rank < cur[0]:
        by_account[acct] = (rank, profile)

if not default_has_sso:
    print("  Your [default] profile has no SSO configuration, so a bare")
    print("  `aws sso login` cannot work -- that is the error you just saw.\n")

if not by_account:
    print("  No SSO profiles found in ~/.aws/config. Set credentials however this")
    print("  machine normally does, then re-run.")
    raise SystemExit(0)

# Sandbox / lab-looking accounts first: that is where this lab belongs.
def sort_key(item):
    acct, (rank, profile) = item
    hint = 0 if any(w in profile for w in ("sandbox", "ese", "lab")) else 1
    return (hint, rank, profile)

picks = [(p, a) for a, (_, p) in sorted(by_account.items(), key=sort_key)][:8]

print("  Pick the account you want the lab in, log in, and pass the profile back:\n")
profile, acct = picks[0]
print(f"    aws sso login --profile {profile}")
print(f"    AWS_PROFILE={profile} DD_API_KEY=<key> ./lab.sh\n")
if len(picks) > 1:
    print("  Other accounts you have access to:")
    for profile, acct in picks[1:]:
        print(f"    {profile}  [{acct}]")
    print()
print(f"  {len(by_account)} accounts available. To find one by id:")
print("    grep -B2 'sso_account_id=<ACCOUNT_ID>' ~/.aws/config | grep '^\\[profile'")
print("  ./lab.sh also takes --aws-profile=NAME")
PY
}

# Some managed AWS credential helpers (Datadog's included) only refresh the
# cached SSO token when stdout is a terminal -- so `aws sts get-caller-identity`
# works when you type it and fails the moment a script captures its output.
# Running one call through a pty warms the cache; plain captures work after that.
aws_warmup() {
  command -v script >/dev/null 2>&1 || return 0
  if [[ "$(uname -s)" == "Darwin" ]]; then
    script -q /dev/null aws sts get-caller-identity >/dev/null 2>&1 || true
  else
    script -qec "aws sts get-caller-identity" /dev/null >/dev/null 2>&1 || true
  fi
}

# Terraform's Go SDK cannot always follow an SSO-managed default profile even
# when the CLI can. Hand it the resolved credentials explicitly.
load_aws_credentials() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi

  local exported attempt
  exported="$(aws configure export-credentials --format env 2>/dev/null || true)"

  # The first pty-backed call often only kicks off the refresh; the second one
  # gets the fresh token. Give it a few rounds before giving up.
  for attempt in 1 2 3; do
    [[ -n "$exported" ]] && break
    [[ "$attempt" == "1" ]] && step "refreshing AWS credentials"
    aws_warmup
    exported="$(aws configure export-credentials --format env 2>/dev/null || true)"
  done

  if [[ -z "$exported" ]]; then
    suggest_sso_profiles
    die "no usable AWS credentials"
  fi

  eval "$exported"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  [[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN
  return 0
}

# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

sha256_prefix() {
  local value="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | cut -c1-8
  else
    printf '%s' "$value" | sha256sum | cut -c1-8
  fi
}

my_public_ip() {
  local ip
  for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
    ip="$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  die "could not determine this machine's public IP (checked checkip.amazonaws.com, ipify, ifconfig.me)"
}

now_utc() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'; }

# "24h" / "90m" / "3d" / "36" (bare = hours) / "0" | "none" -> seconds
ttl_to_seconds() {
  python3 - "$1" <<'PY'
import re, sys
raw = sys.argv[1].strip().lower()
if raw in ("0", "none", "no", "off", ""):
    print(0); raise SystemExit(0)
m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([smhd]?)", raw)
if not m:
    sys.stderr.write(f"cannot parse ttl {raw!r}; use forms like 24h, 90m, 3d, or 0\n")
    raise SystemExit(1)
mult = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 3600}[m.group(2)]
secs = int(float(m.group(1)) * mult)
if secs and secs < 300:
    sys.stderr.write("ttl must be at least 5 minutes (or 0 to disable)\n")
    raise SystemExit(1)
print(secs)
PY
}

utc_plus_seconds() {
  python3 - "$1" <<'PY'
import datetime, sys
delta = datetime.timedelta(seconds=int(sys.argv[1]))
print((datetime.datetime.now(datetime.timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# prints "expired" / "<duration> left" / "no TTL"
ttl_human() {
  python3 - "${1:-}" <<'PY'
import datetime, sys
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
    print("no TTL"); raise SystemExit(0)
try:
    exp = datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
except ValueError:
    print(raw); raise SystemExit(0)
secs = (exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
if secs <= 0:
    print("EXPIRED"); raise SystemExit(0)
h, m = divmod(int(secs) // 60, 60)
print(f"{h}h{m:02d}m left" if h else f"{m}m left")
PY
}

is_expired() {
  [[ -z "${1:-}" ]] && return 1
  [[ "$(ttl_human "$1")" == "EXPIRED" ]]
}

# ---------------------------------------------------------------------------
# state backend
# ---------------------------------------------------------------------------

aws_account_id() { aws sts get-caller-identity --query Account --output text; }

state_bucket_name() { printf 'ddlab-tfstate-%s' "$1"; }

ensure_state_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    return 0
  fi
  step "creating shared state bucket s3://$bucket"
  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
  else
    aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  # ts_creator / ts_team are required by the account tag policy, which alerts on
  # violations -- including for this bucket, which Terraform does not manage.
  aws s3api put-bucket-tagging --bucket "$bucket" --tagging \
    "TagSet=[{Key=creator,Value=matthew.ruyffelaert},{Key=ts_creator,Value=$TS_CREATOR},{Key=ts_team,Value=$TS_TEAM},{Key=please_keep_my_resource,Value=true},{Key=team,Value=enterprise-sales-engineering},{Key=project,Value=ddlab}]" >/dev/null
  ok "bucket ready (versioned, encrypted, private)"
}

tf() { terraform -chdir="$TF_DIR" "$@"; }

# Writes terraform/backend.tf for this instance, then initialises against it.
# Generated rather than committed: one state key per Datadog API key, and a
# partially-configured backend block does not survive `terraform validate`.
write_backend() {
  local bucket="$1" instance="$2" region="$3"
  cat > "$TF_DIR/backend.tf" <<EOF
# GENERATED BY lab.sh -- do not edit, do not commit.
# instance: $instance
terraform {
  backend "s3" {
    bucket       = "$bucket"
    key          = "$STATE_PREFIX/$instance/terraform.tfstate"
    region       = "$region"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
}

tf_init() {
  local bucket="$1" instance="$2" region="$3"
  if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
    warn "terraform/terraform.tfvars exists and will be auto-loaded; lab.sh passes every variable explicitly, so delete it to avoid surprises"
  fi
  write_backend "$bucket" "$instance" "$region"
  tf init -reconfigure -input=false >/dev/null
}

tf_out() { tf output -raw "$1" 2>/dev/null || true; }
tf_out_json() { tf output -json "$1" 2>/dev/null || true; }

# NOTE: deliberately no pipe. `tf state list | grep -q` looks fine but is a trap:
# grep -q exits on the first match, terraform takes SIGPIPE, and `set -o pipefail`
# turns that into a failed pipeline -- so it reported "no instance" for every
# stack that actually existed, which broke join-detection, the ingress union and
# TTL preservation all at once.
stack_exists() {
  local resources
  resources="$(tf state list 2>/dev/null || true)"
  [[ $'\n'"$resources"$'\n' == *$'\n'"aws_ecs_service.app"$'\n'* ]]
}

# ---------------------------------------------------------------------------
# instance metadata (so `list` and `reap` work without a terraform init each)
# ---------------------------------------------------------------------------

meta_uri() { printf 's3://%s/%s/%s/meta.json' "$1" "$STATE_PREFIX" "$2"; }

meta_write() {
  local bucket="$1" instance="$2" expires="$3" alb="$4" site="$5" region="$6" created="$7"
  local tmp
  tmp="$(mktemp)"
  python3 - "$instance" "$expires" "$alb" "$site" "$region" "$created" "$(now_utc)" >"$tmp" <<'PY'
import json, sys
keys = ["instance_id", "expires_at", "alb_dns", "dd_site", "region", "created_at", "last_seen"]
print(json.dumps(dict(zip(keys, sys.argv[1:])), indent=2))
PY
  aws s3 cp "$tmp" "$(meta_uri "$bucket" "$instance")" --only-show-errors >/dev/null
  rm -f "$tmp"
}

meta_read() {
  aws s3 cp "$(meta_uri "$1" "$2")" - 2>/dev/null || true
}

# Reads one field from a meta.json on stdin: meta_read ... | meta_get expires_at
#
# Uses `python3 -c` rather than `python3 -` deliberately: with `-`, the program
# itself arrives on stdin, so the piped JSON is never readable. That bug made
# every field come back empty, which in turn made `reap` believe nothing had
# ever expired.
meta_get() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    print(json.loads(raw).get(sys.argv[1], "") if raw else "")
except Exception:
    print("")
' "${1:?meta_get needs a field name}"
}

# ---------------------------------------------------------------------------
# api key handling -- never written to disk by this script
# ---------------------------------------------------------------------------

resolve_api_key() {
  local key="${OPT_API_KEY:-${DD_API_KEY:-}}"
  if [[ -z "$key" ]]; then
    if [[ -t 0 ]]; then
      printf '%sDatadog API key%s (not echoed): ' "$BOLD" "$RST" >&2
      read -rs key
      printf '\n' >&2
    else
      die "no Datadog API key. Pass --dd-api-key=..., set DD_API_KEY, or run interactively."
    fi
  fi
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [[ -n "$key" ]] || die "empty Datadog API key"
  if [[ ! "$key" =~ ^[0-9a-f]{32}$ ]]; then
    warn "that does not look like a Datadog API key (expected 32 hex characters) -- continuing anyway"
  fi
  printf '%s' "$key"
}

validate_api_key() {
  local key="$1" site="$2"
  if [[ "${OPT_SKIP_VALIDATE:-0}" == "1" ]]; then
    info "key validation skipped"
    return 0
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://api.${site}/api/v1/validate" -H "DD-API-KEY: $key" || echo "000")"
  case "$code" in
    200) ok "API key valid for $site" ;;
    403) die "Datadog rejected that API key for site $site. Wrong key, or wrong --dd-site?" ;;
    000) warn "could not reach api.$site to validate the key -- continuing" ;;
    *)   warn "unexpected HTTP $code validating the key against api.$site -- continuing" ;;
  esac
}

# ---------------------------------------------------------------------------
# ingress
# ---------------------------------------------------------------------------

# Union of the existing CIDR list and this machine's address, newest last,
# capped so a well-travelled lab does not accumulate a hundred stale /32s.
merge_cidrs() {
  local existing_json="$1" mine="$2" replace="$3"
  python3 - "$existing_json" "$mine" "$replace" "$MAX_CIDRS" <<'PY'
import json, sys
existing_raw, mine, replace, cap = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4])
try:
    existing = [c for c in json.loads(existing_raw or "[]") if isinstance(c, str)]
except Exception:
    existing = []
new = f"{mine}/32"
merged = [new] if replace else [c for c in existing if c != new] + [new]
merged = [c for c in merged if not c.endswith("/0")]
if len(merged) > cap:
    merged = merged[-cap:]
print(json.dumps(merged))
PY
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_up() {
  preflight docker
  load_aws_credentials

  local region account bucket key instance mine
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"
  bucket="$(state_bucket_name "$account")"

  key="$(resolve_api_key)"
  instance="$(sha256_prefix "$key")"

  step "lab instance $BOLD$instance$RST  (account $account, region $region)"
  info "instance id is a hash of your API key -- the key itself never touches disk"
  validate_api_key "$key" "${OPT_DD_SITE:-datadoghq.com}"

  ensure_state_bucket "$bucket" "$region"

  step "loading state for $instance"
  tf_init "$bucket" "$instance" "$region"

  local existing=0 existing_cidrs="[]" existing_expires="" created_at
  if stack_exists; then
    existing=1
    existing_cidrs="$(tf_out_json allowed_ingress_cidrs)"
    existing_expires="$(tf_out expires_at)"
    ok "found a running instance -- joining it instead of creating a second one"
  else
    ok "no instance for this key yet -- creating one"
  fi

  mine="$(my_public_ip)"
  local cidrs
  cidrs="$(merge_cidrs "$existing_cidrs" "$mine" "${OPT_REPLACE_IP:-0}")"
  step "ingress"
  info "this machine: $mine/32"
  info "allow list:   $cidrs"

  # TTL: an explicit --ttl always wins; otherwise keep what the stack already has,
  # and fall back to the default for a brand new stack.
  local expires=""
  if [[ -n "${OPT_TTL:-}" ]]; then
    local secs
    secs="$(ttl_to_seconds "$OPT_TTL")"
    [[ "$secs" == "0" ]] || expires="$(utc_plus_seconds "$secs")"
  elif [[ "$existing" == "1" ]]; then
    expires="$existing_expires"
  else
    expires="$(utc_plus_seconds "$(ttl_to_seconds "$DEFAULT_TTL")")"
  fi

  step "self-destruct"
  if [[ -n "$expires" ]]; then
    info "scales to zero tasks at $expires  ($(ttl_human "$expires"))"
    info "extend with --ttl 72h, disable with --ttl 0, remove now with ./lab.sh down"
  else
    warn "no TTL on this instance -- it runs until someone runs ./lab.sh down"
  fi

  created_at="$(meta_read "$bucket" "$instance" | meta_get created_at)"
  [[ -n "$created_at" ]] || created_at="$(now_utc)"

  step "applying (builds and pushes the image on first run; ~5 min)"
  TF_VAR_dd_api_key="$key" tf apply -input=false -auto-approve \
    -var "instance_id=$instance" \
    -var "aws_region=$region" \
    -var "dd_site=${OPT_DD_SITE:-datadoghq.com}" \
    -var "expires_at=$expires" \
    -var "desired_count=${OPT_REPLICAS:-2}" \
    -var "ts_creator=$TS_CREATOR" \
    -var "ts_team=$TS_TEAM" \
    -var "dd_di_redaction_excluded_identifiers=$OPT_REDACT_EXCLUDE" \
    -var "agent_log_level=$([[ "$OPT_DEBUG_TELEMETRY" == "1" ]] && echo debug || echo info)" \
    -var "app_trace_debug=$([[ "$OPT_DEBUG_TELEMETRY" == "1" ]] && echo true || echo false)" \
    -var "allowed_ingress_cidrs=$cidrs"

  # desired_count is ignore_changes (the self-destruct owns it), so an explicit
  # `up` is what brings a scaled-to-zero instance back.
  local cluster service want running
  cluster="$(tf_out ecs_cluster)"; service="$(tf_out ecs_service)"
  want="${OPT_REPLICAS:-2}"
  running="$(aws ecs describe-services --cluster "$cluster" --services "$service" \
    --query 'services[0].desiredCount' --output text 2>/dev/null || echo 0)"
  if [[ "$running" != "$want" ]]; then
    step "scaling service from $running to $want"
    aws ecs update-service --cluster "$cluster" --service "$service" \
      --desired-count "$want" >/dev/null
  fi

  meta_write "$bucket" "$instance" "$expires" "$(tf_out alb_dns_name)" \
    "${OPT_DD_SITE:-datadoghq.com}" "$region" "$created_at"

  local url; url="$(tf_out alb_url)"
  printf '\n%s================================================================%s\n' "$GRN$BOLD" "$RST"
  printf '%s lab %s is up%s\n' "$GRN$BOLD" "$instance" "$RST"
  printf '%s================================================================%s\n' "$GRN$BOLD" "$RST"
  info "URL          $url"
  info "reachable    from $mine/32 only"
  info "self-destruct $(if [[ -n "$expires" ]]; then printf '%s (%s)' "$expires" "$(ttl_human "$expires")"; else printf 'disabled'; fi)"
  info "DD_SERVICE   $(tf_out dd_service)     DD_ENV  $(tf_out dd_env)"
  printf '\n%snext:%s\n' "$BOLD" "$RST"
  info "./lab.sh load 10          drive multi-tenant traffic"
  info "./lab.sh status           health, TTL, ingress"
  info "./lab.sh down             delete everything"
  printf '    then create the Span Tag probe -- see %sdocs/dynamic-instrumentation.md%s\n\n' "$BOLD" "$RST"
}

cmd_status() {
  preflight
  load_aws_credentials
  local region account bucket key instance
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"

  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key in account $account. Create one with ./lab.sh up"

  local cluster service expires url
  cluster="$(tf_out ecs_cluster)"; service="$(tf_out ecs_service)"
  expires="$(tf_out expires_at)"; url="$(tf_out alb_url)"

  step "instance $BOLD$instance$RST"
  info "url            $url"
  info "self-destruct  $(if [[ -n "$expires" ]]; then printf '%s (%s)' "$expires" "$(ttl_human "$expires")"; else printf 'disabled'; fi)"
  info "ingress        $(tf_out_json allowed_ingress_cidrs)"
  info "your IP now    $(my_public_ip)/32"

  aws ecs describe-services --cluster "$cluster" --services "$service" \
    --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}' \
    --output table 2>/dev/null || true

  local health
  health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url/health" || echo "000")"
  if [[ "$health" == "200" ]]; then
    ok "GET /health -> 200"
  else
    warn "GET /health -> $health (if this hangs, your IP changed: run ./lab.sh ip)"
  fi

  if is_expired "$expires"; then
    warn "this instance is past its TTL: tasks have been scaled to zero, but the ALB and VPC shell remain (~\$0.55/day). Run ./lab.sh down."
  fi
}

cmd_ip() {
  preflight
  load_aws_credentials
  local region account bucket key instance mine cidrs
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"

  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key. Create one with ./lab.sh up"

  mine="$(my_public_ip)"
  cidrs="$(merge_cidrs "$(tf_out_json allowed_ingress_cidrs)" "$mine" "${OPT_REPLACE_IP:-0}")"

  step "updating ALB ingress to $cidrs"
  TF_VAR_dd_api_key="$key" tf apply -input=false -auto-approve \
    -var "instance_id=$instance" \
    -var "aws_region=$region" \
    -var "dd_site=${OPT_DD_SITE:-datadoghq.com}" \
    -var "expires_at=$(tf_out expires_at)" \
    -var "ts_creator=$TS_CREATOR" \
    -var "ts_team=$TS_TEAM" \
    -var "allowed_ingress_cidrs=$cidrs" \
    -target=aws_security_group.alb
  ok "$mine/32 can now reach $(tf_out alb_url)"
}

cmd_scale() {
  preflight
  load_aws_credentials
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "usage: ./lab.sh scale <count>"
  local region account bucket key instance
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"
  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key"
  aws ecs update-service --cluster "$(tf_out ecs_cluster)" --service "$(tf_out ecs_service)" \
    --desired-count "$n" >/dev/null
  ok "desired count set to $n"
}

cmd_down() {
  preflight
  load_aws_credentials
  local region account bucket key instance
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"

  if [[ -n "${OPT_INSTANCE:-}" ]]; then
    instance="$OPT_INSTANCE"; key="destroyed-no-key-needed"
  else
    key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"
  fi

  tf_init "$bucket" "$instance" "$region"
  if ! stack_exists; then
    warn "nothing deployed for instance $instance"
    aws s3 rm "s3://$bucket/$STATE_PREFIX/$instance/" --recursive --only-show-errors >/dev/null 2>&1 || true
    ok "state cleaned up"
    return 0
  fi

  step "about to destroy lab instance $BOLD$instance$RST in account $account"
  info "$(tf_out alb_url)"
  if [[ "${OPT_YES:-0}" != "1" ]]; then
    printf '    type %sdestroy%s to confirm: ' "$BOLD" "$RST"
    local answer; read -r answer
    [[ "$answer" == "destroy" ]] || die "aborted"
  fi

  step "destroying (~3-5 min; the ECS service has to drain first)"
  TF_VAR_dd_api_key="$key" tf destroy -input=false -auto-approve \
    -var "instance_id=$instance" \
    -var "aws_region=$region" \
    -var "ts_creator=$TS_CREATOR" \
    -var "ts_team=$TS_TEAM" \
    -var "allowed_ingress_cidrs=[\"127.0.0.1/32\"]"

  step "removing shared state for $instance"
  aws s3 rm "s3://$bucket/$STATE_PREFIX/$instance/" --recursive --only-show-errors >/dev/null 2>&1 || true
  ok "instance $instance is gone. Nothing left to pay for."
}

cmd_list() {
  preflight
  load_aws_credentials
  local region account bucket
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"

  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    info "no lab instances have ever been created in account $account"
    return 0
  fi

  step "lab instances in account $account"
  printf '    %-12s %-22s %-14s %s\n' "INSTANCE" "EXPIRES (UTC)" "STATE" "URL"
  local found=0 id meta expires
  while read -r id; do
    [[ -n "$id" ]] || continue
    found=1
    meta="$(meta_read "$bucket" "$id")"
    expires="$(printf '%s' "$meta" | meta_get expires_at)"
    printf '    %-12s %-22s %-14s %s\n' \
      "$id" \
      "${expires:-—}" \
      "$(ttl_human "$expires")" \
      "http://$(printf '%s' "$meta" | meta_get alb_dns)"
  done < <(aws s3 ls "s3://$bucket/$STATE_PREFIX/" 2>/dev/null | awk '/PRE/{gsub("/","",$2); print $2}')
  [[ "$found" == "1" ]] || info "(none)"
  printf '\n'
  info "destroy one with: ./lab.sh down --instance-id=<INSTANCE> --yes"
}

cmd_reap() {
  preflight
  load_aws_credentials
  local region account bucket
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 || { info "nothing to reap"; return 0; }

  step "looking for expired instances in account $account"
  local expired=() id meta expires
  while read -r id; do
    [[ -n "$id" ]] || continue
    meta="$(meta_read "$bucket" "$id")"
    expires="$(printf '%s' "$meta" | meta_get expires_at)"
    if is_expired "$expires"; then
      expired+=("$id")
      info "$id expired at $expires"
    fi
  done < <(aws s3 ls "s3://$bucket/$STATE_PREFIX/" 2>/dev/null | awk '/PRE/{gsub("/","",$2); print $2}')

  if [[ "${#expired[@]}" -eq 0 ]]; then
    ok "nothing expired"
    return 0
  fi

  if [[ "${OPT_YES:-0}" != "1" ]]; then
    printf '    destroy %d expired instance(s)? type %syes%s: ' "${#expired[@]}" "$BOLD" "$RST"
    local answer; read -r answer
    [[ "$answer" == "yes" ]] || die "aborted"
  fi

  for id in "${expired[@]}"; do
    step "destroying $id"
    OPT_INSTANCE="$id" OPT_YES=1 cmd_down || warn "could not fully destroy $id -- check the AWS console"
  done
}

cmd_url() {
  preflight; load_aws_credentials
  local region account bucket key instance
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"
  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key"
  tf_out alb_url; printf '\n'
}

cmd_load() {
  preflight; load_aws_credentials
  local minutes="${1:-10}"
  local region account bucket key instance
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"
  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key"
  exec "$REPO_ROOT/scripts/loadgen.sh" "$(tf_out alb_url)" "$minutes"
}

cmd_logs() {
  preflight; load_aws_credentials
  local which="${1:-app}"
  local region account bucket key instance group
  region="${OPT_REGION:-${AWS_REGION:-$(aws configure get region || echo us-east-1)}}"
  account="$(aws_account_id)"; bucket="$(state_bucket_name "$account")"
  key="$(resolve_api_key)"; instance="$(sha256_prefix "$key")"
  tf_init "$bucket" "$instance" "$region"
  stack_exists || die "no lab instance for that API key"
  case "$which" in
    app)   group="$(tf_out app_log_group)" ;;
    agent) group="$(tf_out agent_log_group)" ;;
    *)     die "usage: ./lab.sh logs [app|agent]" ;;
  esac
  exec aws logs tail "$group" --follow
}

usage() {
  cat <<EOF
${BOLD}lab.sh $VERSION${RST} -- ECS Fargate + Datadog Dynamic Instrumentation lab

${BOLD}USAGE${RST}
  DD_API_KEY=<key> ./lab.sh [command] [flags]

${BOLD}COMMANDS${RST}
  up                 create the lab, or join an existing one and add your IP (default)
  status             url, TTL, ingress list, task counts, health probe
  ip                 add your current IP to the ALB allow list
  url                print the base URL
  load [minutes]     drive multi-tenant traffic (default 10)
  logs [app|agent]   tail container logs
  scale <count>      change the running task count
  down               destroy this instance and its state
  list               every lab instance in the AWS account
  reap               destroy every expired instance
  help               this

${BOLD}FLAGS${RST}
  --dd-api-key=KEY   Datadog API key (or \$DD_API_KEY, or an interactive prompt)
  --dd-site=SITE     datadoghq.com (default), datadoghq.eu, us3/us5.datadoghq.com, ap1.datadoghq.com
  --ttl=DURATION     self-destruct after 24h (default), 90m, 3d, or 0 to disable
  --replicas=N       Fargate task count (default 2)
  --replace-ip       replace the ingress allow list with just your IP
  --region=REGION    AWS region (default: your AWS CLI region)
  --aws-profile=NAME AWS profile to use (or \$AWS_PROFILE)
  --instance-id=ID   target an instance by id instead of by API key (down only)
  --redact-exclude=L comma-separated identifiers to exempt from Dynamic
                     Instrumentation redaction, e.g. bearerToken,decodedJwt
  --debug-telemetry  agent log level debug + DD_TRACE_DEBUG on the app, for
                     diagnosing "no traces are arriving"
  --skip-validate    do not check the API key against the Datadog API
  --yes              no confirmation prompt (down, reap)

${BOLD}TAGGING${RST}
  This account alerts on missing tags. Every resource -- including the state
  bucket, which Terraform does not manage -- gets ts_creator and ts_team.
  If you are not Matt, export your own before the first run:
    export TS_CREATOR=you@datadoghq.com
    export TS_TEAM=ese            # or: shared

${BOLD}HOW INSTANCES WORK${RST}
  One Datadog API key == one lab instance. The instance id is the first 8 hex
  characters of SHA-256(api key), so:
    * same key, second machine  -> joins the running lab, adds the new IP
    * different key             -> gets its own independent lab
  State lives in s3://ddlab-tfstate-<account-id>/instances/<id>/, which is what
  makes "join from anywhere" work. The API key is never written to disk by this
  script; it is passed to Terraform in the environment and stored only in the
  encrypted, private, versioned state bucket and in AWS Secrets Manager.

${BOLD}EXAMPLES${RST}
  DD_API_KEY=abc... ./lab.sh                      # 24h lab, reachable from here only
  DD_API_KEY=abc... ./lab.sh up --ttl=0           # no self-destruct
  DD_API_KEY=abc... ./lab.sh up --ttl=2h          # I need this for one demo
  DD_API_KEY=abc... ./lab.sh ip                   # joined the hotel wifi
  DD_API_KEY=abc... ./lab.sh down --yes           # gone
  ./lab.sh list                                   # what is running in this account
  ./lab.sh reap --yes                             # tidy up everyone's expired labs
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

COMMAND=""
ARGS=()
OPT_API_KEY=""; OPT_DD_SITE=""; OPT_TTL=""; OPT_REPLICAS=""; OPT_REGION=""
OPT_INSTANCE=""; OPT_REPLACE_IP=0; OPT_YES=0; OPT_SKIP_VALIDATE=0
OPT_REDACT_EXCLUDE=""; OPT_AWS_PROFILE=""; OPT_DEBUG_TELEMETRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dd-api-key=*)  OPT_API_KEY="${1#*=}" ;;
    --dd-api-key)    OPT_API_KEY="${2:-}"; shift ;;
    --dd-site=*)     OPT_DD_SITE="${1#*=}" ;;
    --dd-site)       OPT_DD_SITE="${2:-}"; shift ;;
    --ttl=*)         OPT_TTL="${1#*=}" ;;
    --ttl)           OPT_TTL="${2:-}"; shift ;;
    --replicas=*)    OPT_REPLICAS="${1#*=}" ;;
    --replicas)      OPT_REPLICAS="${2:-}"; shift ;;
    --region=*)      OPT_REGION="${1#*=}" ;;
    --region)        OPT_REGION="${2:-}"; shift ;;
    --instance-id=*) OPT_INSTANCE="${1#*=}" ;;
    --instance-id)   OPT_INSTANCE="${2:-}"; shift ;;
    --replace-ip)    OPT_REPLACE_IP=1 ;;
    --yes|-y)        OPT_YES=1 ;;
    --aws-profile=*)    OPT_AWS_PROFILE="${1#*=}" ;;
    --aws-profile)      OPT_AWS_PROFILE="${2:-}"; shift ;;
    --redact-exclude=*) OPT_REDACT_EXCLUDE="${1#*=}" ;;
    --redact-exclude)   OPT_REDACT_EXCLUDE="${2:-}"; shift ;;
    --debug-telemetry)  OPT_DEBUG_TELEMETRY=1 ;;
    --skip-validate) OPT_SKIP_VALIDATE=1 ;;
    -h|--help|help)  usage; exit 0 ;;
    --version)       printf '%s\n' "$VERSION"; exit 0 ;;
    -*)              die "unknown flag $1 (try ./lab.sh help)" ;;
    *)               if [[ -z "$COMMAND" ]]; then COMMAND="$1"; else ARGS+=("$1"); fi ;;
  esac
  shift
done

[[ -n "$OPT_AWS_PROFILE" ]] && export AWS_PROFILE="$OPT_AWS_PROFILE"

COMMAND="${COMMAND:-up}"
[[ "${#ARGS[@]}" -gt 0 ]] || ARGS=()

case "$COMMAND" in
  up)     cmd_up ;;
  status) cmd_status ;;
  ip)     cmd_ip ;;
  url)    cmd_url ;;
  load)   cmd_load "${ARGS[0]:-10}" ;;
  logs)   cmd_logs "${ARGS[0]:-app}" ;;
  scale)  cmd_scale "${ARGS[0]:-}" ;;
  down)   cmd_down ;;
  list)   cmd_list ;;
  reap)   cmd_reap ;;
  *)      die "unknown command '$COMMAND' (try ./lab.sh help)" ;;
esac
