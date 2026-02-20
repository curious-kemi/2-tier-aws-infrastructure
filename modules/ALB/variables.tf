
variable "alb_security_group" {
  description = "Load Balancer Security Group"
}

variable "alb_subnet_ids" {
    type = list(string)
  description = "subnets for the load balancer"
}


variable "vpc_id" {
  description = "the VPC for the application"
}


variable "target_instance_ids" {
    type = list(string)
  description = "ec2 instances to add to the target group"
}