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

data "aws_iam_role" "cluster_role" {
  name = "AmazonEKSClusterRole"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "worker_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node_role" {
  name               = "AmazonEKSNodeIRSARole"
  assume_role_policy = data.aws_iam_policy_document.worker_trust.json
}

resource "aws_iam_role_policy_attachment" "worker_policy" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryReadOnly"
  ])

  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

data "aws_iam_policy_document" "cluster_oidc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:aws:oidc-provider/${module.eks.oidc_provider}"]
    }
    
    condition {
      test = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_vpc_cni_role" {
  name               = "AmazonEKSVPCCNIRole"
  assume_role_policy = data.aws_iam_policy_document.cluster_oidc_trust.json
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.eks_vpc_cni_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
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
  for_each = { for subnet in aws_subnet.private : subnet.cidr_block => subnet.id }

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.0.4"

  attach_encryption_policy    = false
  create_cloudwatch_log_group = false
  create_iam_role             = false
  enabled_log_types           = null
  create_kms_key              = false
  encryption_config           = null
  name                        = "deks"
  vpc_id                      = data.aws_vpc.default.id
  kubernetes_version          = "1.33"
  iam_role_use_name_prefix    = false
  control_plane_subnet_ids    = data.aws_subnets.default_subnets.ids
  subnet_ids                  = [for subnet in aws_subnet.private : subnet.id]
  endpoint_public_access      = true
  iam_role_arn                = data.aws_iam_role.cluster_role.arn

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }
  eks_managed_node_groups = {
    eks_nodes = {
      instance_types  = ["t3.medium"]
      capacity_type   = "SPOT"
      disk_size       = 8
      min_size        = 1
      max_size        = 2
      desired_size    = 1
      create_iam_role = false
      iam_role_arn    = aws_iam_role.node_role.arn
    }
  }
}
