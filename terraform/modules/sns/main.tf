# modules/sns/main.tf
# Creates SNS topic and email subscription for DevOps notifications

resource "aws_sns_topic" "notifications" {
  name = "${var.project_name}-${var.environment}-sns"

  tags = {
    Name        = "${var.project_name}-${var.environment}-sns"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Email subscription for DevOps team
# Note: After apply, AWS sends a confirmation email that must be clicked!
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
