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

provider "aws" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "cluster_oidc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:aws:oidc-provider/${module.eks.oidc_provider}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:default:s3-readonly-account"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_readonly_role" {
  name               = "EKSPodS3ReadOnlyRole"
  assume_role_policy = data.aws_iam_policy_document.worker_trust.json
}

resource "aws_iam_role_policy_attachment" "s3_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  role       = aws_iam_role.s3_readonly_role.name
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

  attach_encryption_policy               = false
  create_cloudwatch_log_group            = false
  create_iam_role                        = false
  authentication_mode                    = "API"
  cloudwatch_log_group_retention_in_days = 1
  enabled_log_types                      = ["api", "authenticator"]
  create_kms_key                         = false
  encryption_config                      = null
  name                                   = "deks"
  vpc_id                                 = data.aws_vpc.default.id
  kubernetes_version                     = "1.33"
  iam_role_use_name_prefix               = false
  control_plane_subnet_ids               = data.aws_subnets.default_subnets.ids
  subnet_ids                             = [for subnet in aws_subnet.private : subnet.id]
  endpoint_public_access                 = true
  iam_role_arn                           = data.aws_iam_role.cluster_role.arn

  # addons = {
  #   coredns                = {}
  #   kube-proxy             = {}
  #   vpc-cni                = {}
  #   eks-pod-identity-agent = {}
  #   metrics-server         = {}
  # }
  eks_managed_node_groups = {
    eks_nodes = {
      instance_types  = ["t3.medium"]
      capacity_type   = "SPOT"
      min_size        = 1
      max_size        = 2
      desired_size    = 1
      create_iam_role = false
      iam_role_arn    = data.aws_iam_role.node_role.arn
    }
  }
}
