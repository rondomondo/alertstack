variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "az" {
  description = "Availability zone for EC2 and EBS"
  type        = string
  default     = "us-east-1c"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "limitedsuperpowers"
}

variable "ami" {
  description = "Ubuntu 26.04 LTS AMI ID (us-east-1)"
  type        = string
  default     = "ami-091138d0f0d41ff90"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "key_name" {
  description = "EC2 SSH key pair name"
  type        = string
  default     = "alertstack-ec2"
}

variable "subnet_id" {
  description = "Subnet ID for the EC2 instance"
  type        = string
  default     = "subnet-11ce395c"
}

variable "vpc_id" {
  description = "VPC ID for the security group"
  type        = string
  default     = "vpc-e3394a99"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 40
}

variable "deploy_bucket" {
  description = "S3 bucket name for deployment artefacts"
  type        = string
  default     = "alertstack-deploy"
}

variable "state_bucket" {
  description = "S3 bucket name for Tofu remote state"
  type        = string
  default     = "alertstack-tofu-state"
}
