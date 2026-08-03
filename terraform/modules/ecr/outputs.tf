# modules/ecr/outputs.tf
output "repository_urls" {
  value = { for k, r in aws_ecr_repository.repos : k => r.repository_url }
}
output "repository_arns" {
  value = [for r in aws_ecr_repository.repos : r.arn]
}
output "registry_url" {
  # everything before the first "/" — used for docker login
  value = split("/", values(aws_ecr_repository.repos)[0].repository_url)[0]
}
