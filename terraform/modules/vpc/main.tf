# modules/vpc/main.tf
# EKS-ready VPC: 2 public + 2 private (nodes) + 2 DB subnets across 2 AZs.
# Same security philosophy as phase 2: nodes and DB are private,
# outbound via a single NAT Gateway, S3 via free Gateway Endpoint.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required by EKS

  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-igw" })
}

# ---------- Public subnets (×2 AZs) — the ALB requires this ----------
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.project_name}-${var.environment}-public-${local.azs[count.index]}"
    # Tag read by the AWS Load Balancer Controller: "place internet-facing
    # load balancers in these subnets"
    "kubernetes.io/role/elb" = "1"
    # Tag that ties the subnet to our cluster
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ---------- Private subnets for EKS nodes (×2 AZs) ----------
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${var.project_name}-${var.environment}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ---------- Private DB subnets (×2 AZs, required by RDS subnet group) ----------
resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${var.project_name}-${var.environment}-db-${local.azs[count.index]}"
  })
}

# ---------- Routing ----------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Single NAT Gateway (documented cost decision: ~$32/month while alive;
# production would run one per AZ for availability)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-eip-nat" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.tags, { Name = "${var.project_name}-${var.environment}-nat" })
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-rt-private" })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# DB subnets: no internet route at all — RDS needs none
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-rt-db" })
}

resource "aws_route_table_association" "db" {
  count          = 2
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# Free S3 Gateway Endpoint — same as phase 2
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = merge(local.tags, { Name = "${var.project_name}-${var.environment}-vpce-s3" })
}
