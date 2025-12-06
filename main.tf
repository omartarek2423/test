terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "omarmm32345"   # Replace with your bucket name
    key            = "eks/terraform.tfstate"       # Path inside the bucket
    region         = "us-east-1"                   # Bucket region
    dynamodb_table = "terraform-lock-table"        # DynamoDB table for state locking
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# --------------------------------------------------------------------
# DATA: Get AWS Account ID
# --------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# --------------------------------------------------------------------
# VPC with 2 Public Subnets (Required by EKS)
# --------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a", "us-east-1b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  tags = {
    Environment = "dev"
    CreatedBy   = "Terraform"
  }
}

# --------------------------------------------------------------------
# EKS Cluster
# --------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name    = "my-eks-cluster"
  cluster_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true

  # ----------------------------------------------------------------
  # IAM User Access
  # ----------------------------------------------------------------
  access_entries = {
    omarmm = {
      principal_arn = "arn:aws:iam::514005485972:user/omarmm"

      policy_associations = {
        omarmm_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # ----------------------------------------------------------------
  # Node Group: Running in one AZ (us-east-1a)
  # ----------------------------------------------------------------
  eks_managed_node_groups = {
    workers = {
      instance_types = ["t3.small"]
      subnet_ids     = [module.vpc.public_subnets[0]]
      min_size       = 2
      desired_size   = 2
      max_size       = 3
    }
  }

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}
