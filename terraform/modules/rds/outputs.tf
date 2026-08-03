# modules/rds/outputs.tf
output "endpoint" { value = aws_db_instance.main.endpoint } # host:port
output "address"  { value = aws_db_instance.main.address }  # host only
