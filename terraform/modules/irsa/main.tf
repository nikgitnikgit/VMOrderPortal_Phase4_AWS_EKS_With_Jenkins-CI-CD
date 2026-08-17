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

# ---------- Jenkins CI agent: push/scan images in ECR ----------
# Trust: ONLY the jenkins-agent-ci SA in the jenkins namespace.
# Permissions: push images to OUR ECR repos + write build evidence to S3.
# Deliberately NO Kubernetes access and no S3 read: CI builds, nothing else.
# Note: ecr:GetAuthorizationToken MUST be account-wide (AWS API requirement).
data "aws_iam_policy_document" "trust_jenkins_ci" {
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
      values   = ["system:serviceaccount:jenkins:jenkins-agent-ci"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_ci" {
  name               = "${var.project_name}-${var.environment}-jenkins-ci-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_jenkins_ci.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "jenkins_ci" {
  name = "ci-ecr-push"
  role = aws_iam_role.jenkins_ci.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
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
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages"
        ]
        Resource = var.ecr_repo_arns
      },
      {
        Sid      = "S3BuildEvidenceWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.s3_bucket_arn}/builds/*"
      }
    ]
  })
}

# ---------- Jenkins CD agent: read the registry, record deployments ----------
# Trust: ONLY the jenkins-agent-cd SA.
# Permissions: verify an image exists (read-only ECR) + write deployment
# evidence to S3. Deliberately NO ecr:PutImage — CD physically cannot push an
# image even if the pipeline were rewritten to try.
# Kubernetes deploy rights come from the jenkins-deployer Role, not from IAM.
data "aws_iam_policy_document" "trust_jenkins_cd" {
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
      values   = ["system:serviceaccount:jenkins:jenkins-agent-cd"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_cd" {
  name               = "${var.project_name}-${var.environment}-jenkins-cd-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust_jenkins_cd.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "jenkins_cd" {
  name = "cd-registry-read"
  role = aws_iam_role.jenkins_cd.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrReadOnly"
        Effect = "Allow"
        Action = [
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = var.ecr_repo_arns
      },
      {
        Sid      = "S3DeploymentEvidenceWrite"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.s3_bucket_arn}/deployments/*"
      },
      {
        # PutObject alone is not enough: the Record deployment stage lists the
        # prefix back to prove the evidence actually landed, and ListObjectsV2
        # is authorised by s3:ListBucket on the BUCKET arn — not by an object
        # grant. Uploads succeeded while the listing returned AccessDenied.
        #
        # Scoped by prefix condition rather than granted outright. This bucket
        # holds customer orders; a bare ListBucket would let CD enumerate every
        # object in it. The condition confines listing to deployments/, which
        # is the only prefix CD writes.
        Sid      = "S3DeploymentEvidenceList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.s3_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = ["deployments/*"]
          }
        }
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
