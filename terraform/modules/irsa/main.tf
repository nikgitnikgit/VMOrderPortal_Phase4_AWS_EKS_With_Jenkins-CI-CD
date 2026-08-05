# modules/irsa/main.tf
# IRSA = IAM Roles for Service Accounts — the phase 3 replacement for
# phase 2 EC2 instance profiles. Each Kubernetes ServiceAccount is trusted
# by exactly ONE IAM role, scoped to exactly the resources it needs.
# No access keys exist anywhere in the system.

locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Reusable trust policy: "this role may only be assumed by ServiceAccount
# <namespace>/<sa-name> of OUR cluster" — enforced cryptographically via OIDC
data "aws_iam_policy_document" "trust_backend" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:backend-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "trust_worker" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:worker-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---------- Backend: may ONLY write order JSONs to OUR bucket ----------
resource "aws_iam_role" "backend" {
  name               = "${var.project_name}-${var.environment}-backend-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_backend.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "backend_s3" {
  name = "s3-orders-write"
  role = aws_iam_role.backend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${var.s3_bucket_arn}/*"
    }]
  })
}

# ---------- Worker: may ONLY publish to OUR topic + send SES email ----------
resource "aws_iam_role" "worker" {
  name               = "${var.project_name}-${var.environment}-worker-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_worker.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "worker_notify" {
  name = "sns-ses-notify"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*" # SES identities are account-level; region-scoped by endpoint
      }
    ]
  })
}

# NOTE: frontend gets NO role at all — nginx needs zero AWS access.
# Least privilege includes giving nothing when nothing is needed.

# ---------- EBS CSI driver: can manage EBS volumes for PVCs ----------
data "aws_iam_policy_document" "trust_ebs_csi" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project_name}-${var.environment}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_ebs_csi.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------- Jenkins agent: can push/scan images in ECR ----------
# Trust: only the jenkins-agent SA in the jenkins namespace can assume this.
# Permissions: push images to OUR three ECR repos + scan them with Trivy.
# Note: ecr:GetAuthorizationToken MUST be account-wide (AWS API requires it).
data "aws_iam_policy_document" "trust_jenkins_agent" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:jenkins:jenkins-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_agent" {
  name               = "${var.project_name}-${var.environment}-jenkins-agent-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_jenkins_agent.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "jenkins_ecr" {
  name = "ecr-push-scan"
  role = aws_iam_role.jenkins_agent.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # AWS requires this to be account-wide
      },
      {
        Sid    = "EcrPushScan"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = var.ecr_repo_arns # scoped to OUR 3 repos only
      },
      {
        # Build evidence (Trivy reports, cluster state) only.
        # Scoped to the builds/ prefix: Jenkins cannot read, overwrite, or
        # delete the application's order data elsewhere in the bucket.
        Sid      = "S3BuildEvidenceWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.s3_bucket_arn}/builds/*"
      }
    ]
  })
}

# ---------- AWS Load Balancer Controller ----------
# The controller (installed by deploy.sh into kube-system) watches Ingress
# objects and creates/manages real ALBs. It needs AWS permissions — granted
# the same IRSA way as our app services. Policy file = the OFFICIAL policy
# from kubernetes-sigs/aws-load-balancer-controller v3.4.2 — MUST match the chart version pinned in deploy.sh (see ALB_CONTROLLER_VERSION). Lesson from live deploy: unpinned chart + old policy = AccessDenied.
data "aws_iam_policy_document" "trust_alb_controller" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-${var.environment}-alb-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_alb_controller.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "alb-controller-official-policy"
  role   = aws_iam_role.alb_controller.id
  policy = file("${path.module}/alb_iam_policy.json")
}
