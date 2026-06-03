variable "ami_value" {
  description = "value for the ami"
}

variable "instance_type_value" {
  description = "value for instance type"
}

variable "app_subnet_ids" {
  type        = list(string)
  description = "ec2 private subnets"
}

variable "app_security_group_id" {
  type        = list(string)
  description = "the security group for the ec2 instance"
}

variable "az" {
  description = "the availability zone "
}

variable "database_secret_id" {
  type        = string
  description = "Secret manager for database"
}

variable "key_name" {
  description = "Key pair for ec2"
  type        = string
}

variable "jenkins_subnet_id" {
  description = "Public subnet for Jenkins server"
  type        = string
}

variable "jenkins_security_group_id" {
  description = "Security group for Jenkins server"
  type        = list(string)
}

variable "jenkins_instance_type" {
  description = "Instance type for Jenkins server"
  type        = string
  default     = "t2.medium"
}



