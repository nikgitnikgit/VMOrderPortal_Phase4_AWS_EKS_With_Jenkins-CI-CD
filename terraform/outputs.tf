# outputs.tf — everything the deploy/bootstrap scripts and Jenkins need
output "cluster_name"     { value = module.eks.cluster_name }
output "ecr_registry"     { value = module.ecr.registry_url }
output "backend_irsa_role_arn" { value = module.irsa.backend_role_arn }
output "worker_irsa_role_arn"  { value = module.irsa.worker_role_arn }
output "rds_address"      { value = module.rds.address }
output "s3_bucket_name"   { value = module.s3.bucket_name }
output "sns_topic_arn"    { value = module.sns.topic_arn }
output "aws_region"       { value = var.aws_region }
output "vpc_id" { value = module.vpc.vpc_id }
output "alb_controller_role_arn" { value = module.irsa.alb_controller_role_arn }
output "jenkins_ci_role_arn" { value = module.irsa.jenkins_ci_role_arn }
output "jenkins_cd_role_arn" { value = module.irsa.jenkins_cd_role_arn }
output "ses_sender" { value = var.ses_sender }
output "k8s_namespace" { value = var.k8s_namespace }
output "github_repo_url" { value = var.github_repo_url }
output "notification_email" { value = var.notification_email }
output "vpc_cidr" { value = var.vpc_cidr }
