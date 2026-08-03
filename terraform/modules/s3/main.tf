# modules/s3/main.tf
# Creates private S3 bucket for VM order JSON files

resource "aws_s3_bucket" "orders" {
  bucket = var.bucket_name
  # LIVE-DESTROY LESSON (and a phase 2 lesson relearned the hard way):
  # without this, terraform destroy fails with BucketNotEmpty.
  # force_destroy makes Terraform empty the bucket (including versioned
  # objects) before deleting it. destroy.sh ALSO empties it — belt and
  # suspenders for a study project.
  force_destroy = true

  tags = {
    Name        = var.bucket_name
    Project     = var.project_name
    Environment = var.environment
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "orders" {
  bucket = aws_s3_bucket.orders.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "orders" {
  bucket = aws_s3_bucket.orders.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}
