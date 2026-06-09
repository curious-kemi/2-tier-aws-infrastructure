

# Jenkins EC2 Variables
variable "ami_value" {
  description = "value for the ami"
}

variable "instance_type_value" {
  description = "value for instance type"
}

variable "key_name" {
  description = "key pair for the ec2 instances"
}

variable "my_ip" {
  description = "My public IP for Jenkins access"
  type        = string
}

variable "jenkins_instance_type" {
  description = "Instance type for Jenkins server"
  type        = string
  default     = "t2.medium"
}



#VPC Variables 
variable "vpc_cidr" {
  description = "CIDR block range for vpc"
}

variable "public_subnet_cidrs" {
  description = "the cidr range for the public subnet"
}


variable "private_subnet_cidrs" {
  description = "the cidr range for the private subnet"
}

variable "db_subnet_cidrs" {
  description = "the cidr range for the RDS subnet"
}

variable "nat_subnet_cidrs" {
  description = "the cidr range for the NAT subnet"
}

variable "az" {
  description = "the availability zone "
}


/* The variables for the jenkins iam policy (to access the ssh key in the 
secret manager */
variable "env" {
  description = "Environment prefix matching Secrets Manager path"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}