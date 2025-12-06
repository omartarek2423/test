# main.tf - Empty Terraform configuration
terraform {
  required_version = ">= 1.3"
  
  backend "s3" {
    bucket         = "omarmm32345"          # Your S3 bucket
    key            = "eks/terraform.tfstate" # Path to the state file
    region         = "us-east-1"
    dynamodb_table = "terraform-lock-table" # Lock table
    encrypt        = true
  }
}

# No resources defined
