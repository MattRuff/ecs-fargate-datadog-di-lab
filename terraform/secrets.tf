resource "random_password" "jwt_signing_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "dd_api_key" {
  name                    = "${local.name}/datadog-api-key"
  description             = "Datadog API key used by the Agent sidecar"
  recovery_window_in_days = 0

  tags = { Name = "${local.name}-datadog-api-key" }
}

resource "aws_secretsmanager_secret_version" "dd_api_key" {
  secret_id     = aws_secretsmanager_secret.dd_api_key.id
  secret_string = var.dd_api_key
}

resource "aws_secretsmanager_secret" "jwt_signing_key" {
  name                    = "${local.name}/jwt-signing-key"
  description             = "HS256 signing key for the lab's stand-in identity provider"
  recovery_window_in_days = 0

  tags = { Name = "${local.name}-jwt-signing-key" }
}

resource "aws_secretsmanager_secret_version" "jwt_signing_key" {
  secret_id     = aws_secretsmanager_secret.jwt_signing_key.id
  secret_string = random_password.jwt_signing_key.result
}
