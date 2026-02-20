

variable "vpc_cidr" {
    description = "CIDR block range for vpc"
}

#for the application load balancer
variable "public_subnet_cidrs" {
    description = "the cidr range for the public subnets"
}

#for the app server
variable "private_subnet_cidrs" {
    description = "the cidr range for the private subnets"
}

#for the db server
variable "db_subnet_cidrs" {
    description = "the cidr range for the RDS subnet"
}

#for the NAT gateway
variable "nat_subnet_cidrs" {
    description = "the cidr range for the NAT subnet"
}

variable "az" {
    description = "the availability zone "
}
