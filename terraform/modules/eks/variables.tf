# modules/eks/variables.tf
variable "project_name" { type = string }
variable "environment"  { type = string }
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
  default     = "t3.medium" # 4 GiB — room for controller + BuildKit agent
}
