
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


# RDS Variables 
variable "db_username" {
  type      = string
  sensitive = true
}

variable "allocated_storage" {
  description = "the amount of storage to allocate"
  type        = number
  sensitive   = true
}

variable "storage_type" {
  description = "value"
  type        = string
}

variable "engine" {
  description = "the engine for the database"
  type        = string
}

variable "engine_version" {
  description = "database engine version"
  type        = string
}

variable "instance_class" {
  description = "the instance class for the database"
  type        = string
}


# EC2 Variables
variable "ami_value" {
  description = "value for the ami"
}

variable "instance_type_value" {
  description = "value for instance type"
}

variable "key_name" {
  description = "key pair for the ec2 instances"
}