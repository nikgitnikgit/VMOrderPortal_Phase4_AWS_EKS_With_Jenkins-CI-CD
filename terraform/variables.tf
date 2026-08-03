# variables.tf — Phase 4 root variables
variable "project_name" {
  type    = string
  default = "vm-order"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.23.0.0/16"
}

# Two of each — EKS and the ALB require two availability zones
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.23.1.0/24", "10.23.5.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.23.4.0/24", "10.23.6.0/24"]
}

variable "db_subnet_cidrs" {
  type    = list(string)
  default = ["10.23.2.0/24", "10.23.3.0/24"]
}

variable "node_instance_type" {
  type    = string
  default = "t3.small"
}

variable "node_count" {
  description = "EKS worker nodes (our design decision: 3)"
  type        = number
  default     = 3
}

variable "k8s_namespace" {
  description = "Namespace the app runs in (never default!)"
  type        = string
  default     = "devops-app"
}

variable "db_name" {
  type    = string
  default = "vmorders"
}

variable "db_username" {
  type    = string
  default = "vmadmin" # NOTE: "admin" is reserved in RDS PostgreSQL
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "s3_bucket_name" {
  description = "Globally unique, LOWERCASE only (lesson learned in phase 2!)"
  type        = string
}

variable "notification_email" {
  type = string
}

variable "ses_sender" {
  description = "Verified SES sender email (was hardcoded in phase 2 deploy.sh — fixed)"
  type        = string
}

variable "github_repo_url" {
  description = "GitHub repo URL for Jenkins to clone (each contributor sets their own)"
  type        = string
}
