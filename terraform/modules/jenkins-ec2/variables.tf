
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

variable "key_name" {
  description = "Key pair for ec2"
  type        = string
}


variable "ami_value" {
  description = "value for the ami"
}