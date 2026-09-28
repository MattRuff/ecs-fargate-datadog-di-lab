resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = local.name }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}/app"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-app" }
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/ecs/${local.name}/datadog-agent"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-datadog-agent" }
}

locals {
  dd_tags = "env:${var.dd_env},team:enterprise-sales-engineering,creator:matthew.ruyffelaert"

  app_container = {
    name      = "app"
    image     = local.image_uri
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = concat([
      # ---- Unified service tagging. Probes are scoped by service+env, so these
      # ---- three have to match what you pick in the Dynamic Instrumentation UI.
      { name = "DD_ENV", value = var.dd_env },
      { name = "DD_SERVICE", value = var.dd_service },
      { name = "DD_VERSION", value = var.dd_version },
      { name = "DD_TAGS", value = local.dd_tags },

      # ---- Where the tracer sends data: the Agent sidecar. Containers in an
      # ---- awsvpc task share a network namespace, so localhost is the sidecar.
      { name = "DD_AGENT_HOST", value = "127.0.0.1" },
      { name = "DD_TRACE_AGENT_PORT", value = "8126" },
      { name = "DD_DOGSTATSD_PORT", value = "8125" },

      { name = "DD_TRACE_ENABLED", value = "true" },
      { name = "DD_LOGS_INJECTION", value = "true" },
      { name = "DD_TRACE_SAMPLE_RATE", value = "1" },
      { name = "DD_RUNTIME_METRICS_ENABLED", value = "true" },

      # ---- Dynamic Instrumentation. Probes arrive over Remote Configuration,
      # ---- which is why both of these must be on in the tracer *and* the Agent.
      { name = "DD_DYNAMIC_INSTRUMENTATION_ENABLED", value = "true" },
      { name = "DD_REMOTE_CONFIGURATION_ENABLED", value = "true" },
      # Uploads the assembly's symbol map so the UI can autocomplete types,
      # methods and line numbers when you create a probe.
      { name = "DD_SYMBOL_DATABASE_UPLOAD_ENABLED", value = "true" },

      # ---- Application config
      { name = "ASPNETCORE_ENVIRONMENT", value = "Production" },
      { name = "Lab__EnableDevTokenEndpoint", value = "true" },
      ],
      # Tracer diagnostics. Writes to /var/log/datadog/dotnet inside the task,
      # so pair it with agent_log_level = "debug" to see the agent side too.
      var.app_trace_debug ? [{ name = "DD_TRACE_DEBUG", value = "1" }] : [],
      # Dynamic Instrumentation redacts values whose identifier name looks
      # sensitive (password, accessToken, authorization, ...). Locals such as
      # bearerToken and decodedJwt fall into that bucket. Set this variable if a
      # probe needs to read one of them. tenantId is not redacted.
      var.dd_di_redaction_excluded_identifiers == "" ? [] : [
        {
          name  = "DD_DYNAMIC_INSTRUMENTATION_REDACTION_EXCLUDED_IDENTIFIERS"
          value = var.dd_di_redaction_excluded_identifiers
        },
      ],
    )

    secrets = [
      {
        name      = "Jwt__SigningKey"
        valueFrom = aws_secretsmanager_secret.jwt_signing_key.arn
      },
    ]

    dependsOn = [{
      containerName = "datadog-agent"
      condition     = "HEALTHY"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }
  }

  agent_container = {
    name      = "datadog-agent"
    image     = var.datadog_agent_image
    essential = true

    portMappings = [
      { containerPort = 8126, protocol = "tcp" },
      { containerPort = 8125, protocol = "udp" },
    ]

    environment = [
      { name = "DD_SITE", value = var.dd_site },
      { name = "ECS_FARGATE", value = "true" },
      { name = "DD_APM_ENABLED", value = "true" },
      { name = "DD_APM_NON_LOCAL_TRAFFIC", value = "true" },
      { name = "DD_DOGSTATSD_NON_LOCAL_TRAFFIC", value = "true" },
      # Required for Dynamic Instrumentation: the Agent is the channel through
      # which probe definitions reach the tracer.
      { name = "DD_REMOTE_CONFIGURATION_ENABLED", value = "true" },
      { name = "DD_ENV", value = var.dd_env },
      { name = "DD_TAGS", value = local.dd_tags },
      # "debug" surfaces which tracers connected and how many traces arrived --
      # the fastest way to tell an instrumentation problem from a wrong org.
      { name = "DD_LOG_LEVEL", value = var.agent_log_level },
    ]

    secrets = [
      {
        name      = "DD_API_KEY"
        valueFrom = aws_secretsmanager_secret.dd_api_key.arn
      },
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "agent health"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.agent.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "datadog-agent"
      }
    }
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    local.agent_container,
    local.app_container,
  ])

  tags = { Name = local.name }

  depends_on = [null_resource.build_and_push]
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command             = true
  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  propagate_tags                     = "SERVICE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }

  tags = { Name = local.name }

  # The self-destruct schedule scales this service to zero out of band. Without
  # this, the next `./lab.sh ip` would quietly resurrect an expired lab.
  # Use `./lab.sh scale N` to change the replica count on a live stack.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.http]
}
