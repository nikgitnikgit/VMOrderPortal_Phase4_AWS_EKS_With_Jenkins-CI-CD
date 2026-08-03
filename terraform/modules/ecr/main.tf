# modules/ecr/main.tf
# One private registry repository per service image
resource "aws_ecr_repository" "repos" {
  for_each = toset(var.repositories)
  name     = "vm-order-${each.key}"

  # IMMUTABLE: a pushed tag can never be silently replaced — you always
  # know exactly which code runs. Changed code = new version tag.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # free AWS vulnerability scan (bonus evidence)
  }

  # allow terraform destroy even if images exist (study project)
  force_delete = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
