# modules/vpc/variables.tf
variable "project_name" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "cluster_name" { type = string }

# EKS + ALB require at least TWO availability zones — that is the main
# difference from the phase 2 VPC (which was mostly single-AZ)
variable "public_subnet_cidrs" { type = list(string) }  # ALB lives here
variable "private_subnet_cidrs" { type = list(string) } # EKS nodes live here
variable "db_subnet_cidrs" { type = list(string) }      # RDS lives here
