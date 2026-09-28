output "instance_id" {
  description = "Short id for this deployment, derived from the Datadog API key."
  value       = var.instance_id
}

output "alb_url" {
  description = "Base URL of the lab API."
  value       = "http://${aws_lb.main.dns_name}"
}

output "alb_dns_name" {
  description = "ALB hostname without the scheme."
  value       = aws_lb.main.dns_name
}

# Read back by lab.sh so a run from a new location can union the caller's
# current address into the existing list instead of locking the previous one out.
output "allowed_ingress_cidrs" {
  description = "CIDRs currently permitted to reach the ALB."
  value       = var.allowed_ingress_cidrs
}

output "expires_at" {
  description = "When the self-destruct schedule scales this lab to zero, or empty if it has no TTL."
  value       = var.expires_at
}

output "desired_count" {
  description = "Replica count requested at create time. The live count can differ after a self-destruct; see `./lab.sh status`."
  value       = var.desired_count
}

output "ecr_image_uri" {
  description = "Image currently deployed."
  value       = local.image_uri
}

output "ecs_cluster" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "alb_security_group_id" {
  description = "Security group whose ingress list lab.sh manages."
  value       = aws_security_group.alb.id
}

output "dd_service" {
  description = "DD_SERVICE to select when creating a Dynamic Instrumentation probe."
  value       = var.dd_service
}

output "dd_env" {
  description = "DD_ENV to select when creating a Dynamic Instrumentation probe."
  value       = var.dd_env
}

output "app_log_group" {
  description = "CloudWatch log group for the app container."
  value       = aws_cloudwatch_log_group.app.name
}

output "agent_log_group" {
  description = "CloudWatch log group for the Datadog Agent sidecar."
  value       = aws_cloudwatch_log_group.agent.name
}
