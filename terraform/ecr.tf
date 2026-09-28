resource "aws_ecr_repository" "app" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = { Name = local.name }
}

locals {
  app_dir = "${path.module}/../app"

  # Hash the application sources so editing the app produces a new image tag,
  # which in turn produces a new task definition and a rolling deploy.
  app_files = [
    for f in fileset(local.app_dir, "**") : f
    if !startswith(f, "bin/") && !startswith(f, "obj/")
  ]

  app_source_hash = sha1(join("", [
    for f in local.app_files : filesha1("${local.app_dir}/${f}")
  ]))

  image_tag = substr(local.app_source_hash, 0, 12)
  image_uri = "${aws_ecr_repository.app.repository_url}:${local.image_tag}"
}

# Builds linux/amd64 and pushes to ECR. Requires docker + aws CLI on the machine
# running terraform. If you would rather drive the build yourself, run
# scripts/build_and_push.sh by hand and this resource becomes a no-op on re-apply.
resource "null_resource" "build_and_push" {
  triggers = {
    image_uri      = local.image_uri
    tracer_version = var.dotnet_tracer_version
  }

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/build_and_push.sh"
    interpreter = ["/bin/bash", "-c"]

    environment = {
      AWS_REGION     = var.aws_region
      ECR_REPO_URL   = aws_ecr_repository.app.repository_url
      IMAGE_TAG      = local.image_tag
      TRACER_VERSION = var.dotnet_tracer_version
      APP_DIR        = abspath(local.app_dir)
    }
  }

  depends_on = [aws_ecr_repository.app]
}
