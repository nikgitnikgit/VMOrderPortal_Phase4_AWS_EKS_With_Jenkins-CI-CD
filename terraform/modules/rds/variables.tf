# modules/rds/variables.tf
variable "project_name" { type = string }
variable "environment"  { type = string }
variable "db_name"      { type = string }
variable "db_username"  { type = string }
variable "db_password" {
  type      = string
  sensitive = true
}
variable "db_instance_class"  { type = string }
variable "private_subnet_id"  { type = string }
variable "private_subnet_id2" { type = string }
variable "vpc_id"             { type = string }
# Phase 3 change: instead of backend/worker EC2 SGs, port 5432 opens to
# the EKS NODE security group — pods live on nodes, so DB traffic
# originates from node addresses
variable "eks_node_sg_id" { type = string }
