terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.5.0"
    }
  }
  backend "s3" {
    bucket = ""
    key    = ""
    region = ""
  }
  # backend "local" {

  # }
}

variable "user_name" {
  description = "The name of the IAM user to grant access to the EKS cluster"
  type        = string
}

provider "aws" {}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
resource "aws_subnet" "private" {
  for_each = toset(["172.31.48.0/20", "172.31.64.0/20"])

  vpc_id     = data.aws_vpc.default.id
  cidr_block = each.value
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_route_table_association" "private" {
  for_each = { for subnet in aws_subnet.private : subnet.cidr_block => subnet.id }

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}

resource "aws_eip" "nat_ip" {}

resource "aws_nat_gateway" "nat" {
  subnet_id     = data.aws_subnets.default_subnets.ids[0]
  allocation_id = aws_eip.nat_ip.allocation_id
}

resource "aws_route" "nat_route" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

data "aws_iam_role" "cluster_role" {
  name = "AmazonEKSClusterRole"
}

data "aws_iam_role" "node_role" {
  name = "AmazonEKSNodeRole"
}
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.4"

  enabled_log_types                      = ["api"]
  create_iam_role                        = false
  authentication_mode                    = "API"
  create_kms_key                         = false
  encryption_config                      = null
  name                                   = "deks"
  vpc_id                                 = data.aws_vpc.default.id
  kubernetes_version                     = "1.33"
  iam_role_use_name_prefix               = false
  control_plane_subnet_ids               = data.aws_subnets.default_subnets.ids
  subnet_ids                             = [for subnet in aws_subnet.private : subnet.id]
  endpoint_public_access = true
  iam_role_arn           = data.aws_iam_role.cluster_role.arn

  addons = {
    coredns        = {}
    metrics-server = {}
    kube-proxy = {
      before_compute = true
    }
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }
  eks_managed_node_groups = {
    eks_nodes = {
      instance_types  = ["t3.medium"]
      disk_size       = 20
      capacity_type   = "SPOT"
      min_size        = 1
      max_size        = 2
      desired_size    = 1
      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.node_role.arn
    }
  }
}
