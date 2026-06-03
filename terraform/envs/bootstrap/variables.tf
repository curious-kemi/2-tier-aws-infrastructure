

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

variable "my_ip" {
  description = "My public IP for Jenkins access"
  type        = string
}

variable "jenkins_instance_type" {
  description = "Instance type for Jenkins server"
  type        = string
  default     = "t2.medium"
}
