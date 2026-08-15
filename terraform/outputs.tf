# outputs.tf — everything the deploy/bootstrap scripts and Jenkins need
output "cluster_name" { value = module.eks.cluster_name }
output "ecr_registry" { value = module.ecr.registry_url }
output "backend_irsa_role_arn" { value = module.irsa.backend_role_arn }
output "worker_irsa_role_arn" { value = module.irsa.worker_role_arn }
output "rds_address" { value = module.rds.address }
output "s3_bucket_name" { value = module.s3.bucket_name }
output "sns_topic_arn" { value = module.sns.topic_arn }
output "aws_region" { value = var.aws_region }
output "vpc_id" { value = module.vpc.vpc_id }
output "alb_controller_role_arn" { value = module.irsa.alb_controller_role_arn }
output "jenkins_ci_role_arn" { value = module.irsa.jenkins_ci_role_arn }
output "jenkins_cd_role_arn" { value = module.irsa.jenkins_cd_role_arn }
output "ses_sender" { value = var.ses_sender }
output "k8s_namespace" { value = var.k8s_namespace }
output "github_repo_url" { value = var.github_repo_url }
output "notification_email" { value = var.notification_email }
output "vpc_cidr" { value = var.vpc_cidr }

# REVIEW FIX 4.7 — destroy.sh verifies leftovers by tag, and every module tags
# resources with Project = var.project_name. The script must read this BEFORE
# `terraform destroy`, because afterwards the state is empty and no output can
# be resolved at all.
output "project_name" { value = var.project_name }

# REVIEW FIX 4.6 — the backend/worker NetworkPolicies used to allow port 5432
# to the entire VPC CIDR. They now allow it only to the database subnets, so
# those CIDRs have to reach the cluster the same way vpc_cidr already does:
# configure-jenkins.sh reads this output and injects it as a Jenkins global
# env var, and Jenkinsfile-cd passes it to Helm.
output "db_subnet_cidrs" { value = var.db_subnet_cidrs }

# REVIEW FIX 2.3 — sensitive output so install-jenkins.sh can read the password
# structurally instead of parsing terraform.tfvars with grep/cut.
# Marking it sensitive keeps it out of `terraform output` (no args) and out of
# apply logs; `terraform output -raw db_password` still returns it, which is
# exactly the controlled access the bootstrap script needs.
# This exposes nothing new: db_password was already stored in plain text inside
# the state file, which is why the state backend is encrypted and private.
output "db_password" {
  value     = var.db_password
  sensitive = true
}
