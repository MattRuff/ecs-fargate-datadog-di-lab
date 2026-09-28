# ---------------------------------------------------------------------------
# 24-hour (or any --ttl) self-destruct.
#
# A one-time EventBridge schedule calls ecs:UpdateService with DesiredCount 0
# at `expires_at`. Deliberately codeless -- no Lambda, no container, nothing
# that can fail to deploy -- because the whole point is that it still fires
# when whoever created the lab has closed their laptop and forgotten about it.
#
# What this does NOT do is delete the ALB and VPC shell (~$0.55/day). That is
# `./lab.sh down`, or `./lab.sh reap`, which sweeps expired instances.
# ---------------------------------------------------------------------------

locals {
  self_destruct_enabled = var.expires_at != "" ? 1 : 0

  # EventBridge one-time schedules want at(yyyy-MM-ddTHH:mm:ss) with no zone
  # suffix, paired with an explicit schedule_expression_timezone.
  self_destruct_at = var.expires_at == "" ? "" : formatdate("YYYY-MM-DD'T'hh:mm:ss", var.expires_at)
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "self_destruct" {
  count = local.self_destruct_enabled

  name               = "${local.name}-selfdestruct"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json

  tags = { Name = "${local.name}-selfdestruct" }
}

data "aws_iam_policy_document" "self_destruct" {
  statement {
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [aws_ecs_service.app.id]
  }
}

resource "aws_iam_role_policy" "self_destruct" {
  count = local.self_destruct_enabled

  name   = "${local.name}-selfdestruct"
  role   = aws_iam_role.self_destruct[0].id
  policy = data.aws_iam_policy_document.self_destruct.json
}

resource "aws_scheduler_schedule" "self_destruct" {
  count = local.self_destruct_enabled

  name        = "${local.name}-selfdestruct"
  description = "Scales ${local.name} to zero tasks at ${var.expires_at}"

  schedule_expression          = "at(${local.self_destruct_at})"
  schedule_expression_timezone = "UTC"

  # Fire exactly on time, then delete the schedule so nothing is left behind.
  action_after_completion = "DELETE"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.self_destruct[0].arn

    input = jsonencode({
      Cluster      = aws_ecs_cluster.main.name
      Service      = aws_ecs_service.app.name
      DesiredCount = 0
    })

    retry_policy {
      maximum_retry_attempts = 10
    }
  }
}
