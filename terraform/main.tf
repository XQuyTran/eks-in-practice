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
}

provider "aws" {

}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default_subnet" {
  for_each = toset(data.aws_subnets.default_subnets.ids)
  id       = each.value
}

locals {
  default_newbit       = tonumber(split("/", data.aws_subnet.default_subnet[data.aws_subnets.default_subnets.ids[0]].cidr_block)[1]) - tonumber(split("/", data.aws_vpc.default.cidr_block)[1])
  num_existing_subnets = length(data.aws_subnets.default_subnets.ids)
  num_private_subnets  = 2
  proposed_cidrs       = [for i in range(local.num_private_subnets) : cidrsubnet(data.aws_vpc.default.cidr_block, local.default_newbit, local.num_existing_subnets + i)]
}

resource "aws_subnet" "private" {
  for_each = toset(local.proposed_cidrs)

  vpc_id     = data.aws_vpc.default.id
  cidr_block = each.value
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_route_table_association" "private" {
  for_each = {for subnet in aws_subnet.private : subnet.cidr_block => subnet.id}

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.4"

  attach_encryption_policy               = false
  create_cloudwatch_log_group            = false
  enabled_log_types                      = null
  create_kms_key                         = false
  encryption_config                      = null
  name                                   = "deks"
  vpc_id                                 = data.aws_vpc.default.id
  kubernetes_version                     = "1.33"
  iam_role_use_name_prefix               = false
  control_plane_subnet_ids               = data.aws_subnets.default_subnets.ids
  subnet_ids                             = [for subnet in aws_subnet.private : subnet.id]
  endpoint_public_access                 = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }
  eks_managed_node_groups = {
    eks_nodes = {
      disk_size = 8
      desired_capacity = 1
      max_capacity     = 2
      min_capacity     = 1

      instance_market_options = {
        market_type = "spot"
        spot_options = {
          spot_instance_type = "t3.medium"
        }
      }
    }
  }
}
