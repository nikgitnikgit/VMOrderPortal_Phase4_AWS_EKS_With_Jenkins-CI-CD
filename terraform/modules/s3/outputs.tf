# modules/s3/outputs.tf
output "bucket_name" { value = aws_s3_bucket.orders.bucket }
output "bucket_arn" { value = aws_s3_bucket.orders.arn }
