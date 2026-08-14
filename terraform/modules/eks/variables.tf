# modules/eks/variables.tf
variable "project_name" { type = string }
variable "environment" { type = string }
variable "cluster_name" { type = string }

variable "kubernetes_version" {
  type = string
  # 1.35 — chosen because it is in EKS STANDARD support.
  # This is a cost decision, not just a freshness one: a version in
  # extended support is billed at $0.60/cluster/hour instead of $0.10,
  # and EKS enrols you automatically with no opt-in. 1.31 (our phase 3
  # pin) entered extended support and would have cost 6x for the control
  # plane alone. Check the EKS version calendar before each new cycle.
  default = "1.35"
}

variable "private_subnet_ids" { type = list(string) }

# REVIEW FIX 2.1 — no default ON PURPOSE. A default here would be either
# insecure (0.0.0.0/0, the thing we are fixing) or wrong for everyone but its
# author. Terraform prompts for it, and tests/run_all.sh T3.2 asserts that
# every variable without a default appears in terraform.tfvars.example.
variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Never 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = !contains(var.api_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 defeats the purpose of this variable. List explicit /32 addresses."
  }

  validation {
    condition     = length(var.api_public_access_cidrs) > 0
    error_message = "At least one CIDR is required, or nobody can run kubectl."
  }
}

variable "node_instance_type" {
  type    = string
  default = "t3.small" # 2 GB RAM — realistic minimum; system pods eat ~30% of a node
}

variable "node_desired" {
  type    = number
  default = 3 # the 3-node decision from our design discussion
}

variable "node_min" {
  type    = number
  default = 3
}

variable "node_max" {
  type    = number
  default = 4
}

variable "jenkins_node_instance_type" {
  description = "Instance type for the Jenkins node group (needs more RAM than app nodes)"
  type        = string
  # m7i-flex.large = 2 vCPU / 8 GiB.
  # Chosen because it is FREE-TIER ELIGIBLE. AWS accounts created on or after
  # 2025-07-15 are hard-restricted to: t3.micro, t3.small, t4g.micro,
  # t4g.small, c7i-flex.large, m7i-flex.large. Anything else fails at launch
  # with InvalidParameterCombination and the node group times out after ~30
  # minutes with an empty health.issues list — a slow, confusing failure.
  # t3.medium (the obvious choice) is NOT on that list.
  # On an unrestricted account, t3.medium or m7i-flex.large both work.
  default = "m7i-flex.large"
}
