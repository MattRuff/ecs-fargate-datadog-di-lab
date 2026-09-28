terraform {
  # Terraform 1.10+ for S3-native state locking (use_lockfile).
  required_version = ">= 1.10"

  # The S3 backend lives in terraform/backend.tf, which lab.sh generates per
  # instance (gitignored). It is not committed because a partially-configured
  # backend block fails `terraform validate`, and because each Datadog API key
  # gets its own state key. Run `./lab.sh` rather than bare terraform.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Mandatory tagging standard. Every resource that supports tags inherits these.
  default_tags {
    tags = merge(
      {
        creator                 = "matthew.ruyffelaert"
        please_keep_my_resource = "true"
        team                    = "enterprise-sales-engineering"
        project                 = var.project_name
        lab_instance            = var.instance_id

        # Required by the account's tag policy, which alerts on violations.
        # ts_creator must be a full Datadog email; ts_team accepts ese | shared.
        ts_creator = var.ts_creator
        ts_team    = var.ts_team
      },
      # Stamped when the stack is created with a TTL, so an expired lab is
      # obvious in the console and to `./lab.sh reap`.
      var.expires_at == "" ? {} : { expires_at = var.expires_at },
    )
  }
}
