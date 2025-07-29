terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.5.0"
    }
  }
}

provider "aws" {

}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_subnets" {
  filter {
    name   = "vpc_id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default_subnet" {
  for_each = toset(data.aws_subnets.default_subnets.ids)
  id       = each.value
}

data "aws_availability_zones" "available" {}

locals {
  default_newbit       = tonumber(split("/", data.aws_subnet.default_subnet[0].cidr_block)[1]) - tonumber(split("/", data.aws_vpc.default.cidr_block)[1])
  num_existing_subnets = length(data.aws_subnets.default_subnets.ids)
  num_private_subnets  = 2
  proposed_cidrs       = [for i in range(local.num_private_subnets) : cidrsubnet(data.aws_vpc.default.cidr_block, local.default_newbit, local.num_existing_subnets + i)]
}

resource "aws_subnet" "private" {
  for_each = toset(local.proposed_cidrs)

  vpc_id            = data.aws_vpc.default.id
  cidr_block        = each.value
  availability_zone = element(data.aws_availability_zones.available.names, each.key)
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.4"

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }
  cloudwatch_log_group_retention_in_days = 1
  create_kms_key                         = false
  eks_managed_node_groups = {
    eks_nodes = {
      desired_capacity = 1
      max_capacity     = 2
      min_capacity     = 1

      instance_type = "t3.medium"
    }
  }
  name   = "eks-cluster"
  vpc_id = data.aws_vpc.default.id
  subnet_ids = concat(
    slice(data.aws_subnets.default_subnets.ids, 0, local.num_private_subnets),
    aws_subnet.private[*].id
  )
}

