# modules/rds/main.tf
# Creates PostgreSQL RDS instance in private subnet

# DB subnet group — requires at least 2 subnets in different AZs
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-subnet-group"
  subnet_ids = [var.private_subnet_id, var.private_subnet_id2]

  tags = {
    Name        = "${var.project_name}-${var.environment}-subnet-group"
    Project     = var.project_name
    Environment = var.environment
  }
}

# PostgreSQL RDS instance
resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-${var.environment}-rds"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Free tier settings
  publicly_accessible    = false
  skip_final_snapshot    = true
  backup_retention_period = 0
  multi_az               = false

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Security group for RDS — phase 3 version.
# Only EKS nodes may reach PostgreSQL; nothing else, nowhere else.
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-sg-rds"
  description = "PostgreSQL access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-sg-rds"
    Project     = var.project_name
    Environment = var.environment
  }
}
