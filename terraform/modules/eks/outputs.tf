# modules/eks/outputs.tf
output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
# The security group EKS attaches to nodes — RDS allows 5432 from it
output "node_security_group_id" { value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.main.arn }
output "oidc_provider_url" { value = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "") }
