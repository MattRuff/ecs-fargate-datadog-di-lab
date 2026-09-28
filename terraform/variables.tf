variable "aws_region" {
  description = "AWS region for the lab."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for every resource in the lab. Kept short: it feeds ALB and target group names, which cap at 32 characters."
  type        = string
  default     = "ddlab"
}

variable "instance_id" {
  description = <<-EOT
    Short, stable id for this deployment. lab.sh derives it from a SHA-256 of the
    Datadog API key, so one API key always maps to one stack and a different key
    gets its own. Every resource name and the state file key include it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{6,12}$", var.instance_id))
    error_message = "instance_id must be 6-12 lowercase alphanumeric characters."
  }
}

variable "expires_at" {
  description = <<-EOT
    RFC3339 UTC timestamp at which this lab self-destructs, or "" for no TTL.
    When set, a one-time EventBridge schedule scales the ECS service to zero at
    that moment. lab.sh computes this from --ttl and preserves it across runs.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.expires_at == "" || can(formatdate("YYYY-MM-DD", var.expires_at))
    error_message = "expires_at must be \"\" or an RFC3339 timestamp, e.g. \"2026-09-29T18:00:00Z\"."
  }
}

variable "dd_api_key" {
  description = "Datadog API key. The key's org must have Remote Configuration enabled for Dynamic Instrumentation to work."
  type        = string
  sensitive   = true
}

variable "dd_site" {
  description = "Datadog site (datadoghq.com, datadoghq.eu, us3.datadoghq.com, us5.datadoghq.com, ap1.datadoghq.com, ddog-gov.com)."
  type        = string
  default     = "datadoghq.com"
}

variable "dd_env" {
  description = "Value of DD_ENV. Dynamic Instrumentation probes are scoped by service + env, so this must match what you select in the UI."
  type        = string
  default     = "fargate-lab"
}

variable "dd_service" {
  description = "Value of DD_SERVICE. This is the service you will attach probes to."
  type        = string
  default     = "settlements-api"
}

variable "dd_version" {
  description = "Value of DD_VERSION."
  type        = string
  default     = "1.0.0"
}

variable "dotnet_tracer_version" {
  description = "Datadog .NET tracer version baked into the image."
  type        = string
  default     = "3.54.0"
}

variable "datadog_agent_image" {
  description = "Datadog Agent sidecar image. Needs 7.41+ for Remote Configuration."
  type        = string
  default     = "public.ecr.aws/datadog/agent:7"
}

variable "task_cpu" {
  description = "Fargate task CPU units."
  type        = string
  default     = "1024"
}

variable "task_memory" {
  description = "Fargate task memory (MiB)."
  type        = string
  default     = "2048"
}

variable "desired_count" {
  description = "Number of Fargate tasks. Keep at 1 or 2 for a lab."
  type        = number
  default     = 2
}

variable "allowed_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the ALB on port 80. Required, with no default, and an
    open CIDR is rejected: this account's rules only permit ingress from the
    operator's own address. Get yours with `make myip`.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "allowed_ingress_cidrs must list at least one CIDR. Run `make myip` to get yours."
  }

  validation {
    condition = length([
      for c in var.allowed_ingress_cidrs : c
      if c == "0.0.0.0/0" || endswith(c, "/0")
    ]) == 0
    error_message = "Open ingress is not permitted. Use a specific address, e.g. [\"203.0.113.4/32\"]."
  }

  validation {
    condition = alltrue([
      for c in var.allowed_ingress_cidrs : can(cidrnetmask(c))
    ])
    error_message = "Every entry must be a valid IPv4 CIDR, e.g. \"203.0.113.4/32\"."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 7
}

variable "dd_di_redaction_excluded_identifiers" {
  description = <<-EOT
    Comma-separated identifiers to exclude from Dynamic Instrumentation's default
    redaction, e.g. "bearerToken,decodedJwt". Leave empty unless a probe needs to
    read a variable whose name looks sensitive. See docs/dynamic-instrumentation.md.
  EOT
  type        = string
  default     = ""
}

variable "ts_creator" {
  description = "Required by the account tag policy: the creator's full Datadog email address."
  type        = string
  default     = "matthew.ruyffelaert@datadoghq.com"

  validation {
    condition     = can(regex("^[^@ ]+@datadoghq\\.com$", var.ts_creator))
    error_message = "ts_creator must be a full @datadoghq.com email address."
  }
}

variable "ts_team" {
  description = "Required by the account tag policy. Allowed values: ese, shared."
  type        = string
  default     = "ese"

  validation {
    condition     = contains(["ese", "shared"], var.ts_team)
    error_message = "ts_team must be either \"ese\" or \"shared\"."
  }
}

variable "agent_log_level" {
  description = "Datadog Agent sidecar log level. Set to \"debug\" to see trace-receiver activity (which tracers connected, how many traces arrived) in CloudWatch."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["trace", "debug", "info", "warn", "error", "critical", "off"], var.agent_log_level)
    error_message = "agent_log_level must be one of: trace, debug, info, warn, error, critical, off."
  }
}

variable "app_trace_debug" {
  description = "Set DD_TRACE_DEBUG=1 on the app container. Use when diagnosing why spans are not arriving; noisy otherwise."
  type        = bool
  default     = false
}
