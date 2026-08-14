# modules/irsa/outputs.tf
output "backend_role_arn" { value = aws_iam_role.backend.arn }
output "worker_role_arn" { value = aws_iam_role.worker.arn }
output "alb_controller_role_arn" { value = aws_iam_role.alb_controller.arn }
output "ebs_csi_role_arn" { value = aws_iam_role.ebs_csi.arn }
output "jenkins_ci_role_arn" { value = aws_iam_role.jenkins_ci.arn }
output "jenkins_cd_role_arn" { value = aws_iam_role.jenkins_cd.arn }
