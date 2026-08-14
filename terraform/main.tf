# main.tf — VM Order Portal, Phase 4: EKS infrastructure + Jenkins CI/CD
# Creates: VPC, EKS cluster (3 app nodes + 1 Jenkins node), ECR repos,
# IRSA roles, RDS, S3, SNS.
#
# Division of labor (phase 4):
#   Terraform  = infrastructure (AWS resources only)
#   Bootstrap  = namespace + app Secret + add-ons + Jenkins (runs on YOUR
#                laptop, reading Terraform outputs — Jenkins never sees the
#                DB password)
#   Jenkins    = build images, push to ECR, deploy with Helm
#
# NOTE: we deliberately do NOT configure the kubernetes or helm providers
# here. Both need the cluster endpoint at provider-configuration time, which
# does not exist on the first apply. It appears to work on create and then
# breaks on destroy. The bootstrap script does that work instead.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  # Remote state: run ./bootstrap-state.sh once (same pattern as phase 2);
  # it generates backend.tf and migrates state to S3 + DynamoDB locking.
}

provider "aws" {
  region = var.aws_region
}

locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"
}

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  environment          = var.environment
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  cluster_name         = local.cluster_name
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
}

module "eks" {
  source = "./modules/eks"

  project_name       = var.project_name
  environment        = var.environment
  cluster_name       = local.cluster_name
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.node_instance_type
  node_desired       = var.node_count
  node_min           = var.node_count
  node_max           = var.node_count + 1

  api_public_access_cidrs = var.api_public_access_cidrs
}

module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  repositories = ["frontend", "backend", "worker", "jenkins-agent"]
}

module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
  environment  = var.environment
  bucket_name  = var.s3_bucket_name
}

module "sns" {
  source = "./modules/sns"

  project_name       = var.project_name
  environment        = var.environment
  notification_email = var.notification_email
}

module "rds" {
  source = "./modules/rds"

  project_name       = var.project_name
  environment        = var.environment
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
  private_subnet_id  = module.vpc.db_subnet_ids[0]
  private_subnet_id2 = module.vpc.db_subnet_ids[1]
  vpc_id             = module.vpc.vpc_id
  eks_node_sg_id     = module.eks.node_security_group_id
}

module "irsa" {
  source = "./modules/irsa"

  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = var.k8s_namespace
  s3_bucket_arn     = module.s3.bucket_arn
  sns_topic_arn     = module.sns.topic_arn
  ecr_repo_arns     = module.ecr.repository_arns
}

# ---------- EBS CSI driver addon ----------
# Lives in the ROOT module on purpose: it needs the cluster from module.eks
# AND the IRSA role from module.irsa. Wiring it inside modules/eks would
# create the cycle eks -> irsa -> eks. At root, both are already resolved.
#
# Required for PersistentVolumeClaims backed by EBS (Jenkins needs one).
# Since K8s 1.23 EKS does NOT include this by default; without it the PVC
# sits in Pending forever with no useful error and Jenkins never starts.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa.ebs_csi_role_arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
