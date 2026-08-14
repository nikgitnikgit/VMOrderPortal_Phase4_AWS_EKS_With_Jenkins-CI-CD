# modules/eks/main.tf
# EKS control plane + TWO managed node groups + OIDC provider (IRSA foundation)
# Phase 4: app nodes (t3.small ×3) stay cheap; Jenkins gets its own larger
# node, tainted so app pods can't land on it. See cookbook §4.1.

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ---------- IAM role the CONTROL PLANE assumes ----------
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------- The cluster ----------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version # pinned — never "latest" thinking here either

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_public_access  = true # your kubectl connects from home
    endpoint_private_access = true # nodes talk to the API privately
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
  tags       = local.tags
}

# ---------- IAM role the NODES assume ----------
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

# Three standard managed policies every EKS node needs:
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" # join cluster
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" # pod networking
}
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" # pull our images
}

# ---------- Node group 1: application nodes (unchanged size) ----------
# No taint — app pods, system pods, anything without special scheduling
# needs can land here. Three t3.small nodes as in phase 3.
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-app-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids # nodes are PRIVATE — phase 2 lesson kept
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired
    min_size     = var.node_min
    max_size     = var.node_max
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = merge(local.tags, { Role = "app" })
}

# ---------- Node group 2: Jenkins node (bigger, tainted) ----------
# Tainted so ONLY pods with a matching toleration land here (Jenkins
# controller + build agents). App pods physically cannot reach this node.
# m7i-flex.large (2 vCPU / 8 GiB) gives the controller and BuildKit room.
# NOTE: instance type must be FREE-TIER ELIGIBLE on post-2025-07-15 accounts.
resource "aws_eks_node_group" "jenkins" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-jenkins-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = [var.jenkins_node_instance_type]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2 # room to scale if builds queue up
  }

  taint {
    key    = "role"
    value  = "jenkins"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
  tags = merge(local.tags, { Role = "jenkins" })
}

# ---------- OIDC provider: the foundation of IRSA ----------
# Lets AWS IAM cryptographically trust Kubernetes ServiceAccount tokens,
# so pods can assume IAM roles with NO access keys anywhere.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  tags            = local.tags
}

# ---------- VPC CNI addon with NetworkPolicy ENFORCEMENT ----------
# Critical detail: without enableNetworkPolicy=true the AWS VPC CNI
# silently IGNORES all NetworkPolicy objects — they would validate,
# apply, and do absolutely nothing. This addon setting turns them
# into real, enforced firewall rules between pods.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.app]
  tags       = local.tags
}

# NOTE: the EBS CSI driver addon is created in the ROOT module, not here.
# It needs an IRSA role ARN from modules/irsa, and modules/irsa needs the
# OIDC provider from this module — wiring it here creates a dependency
# cycle (eks -> irsa -> eks) that Terraform refuses to plan.
