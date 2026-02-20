

# create vpc
resource "aws_vpc" "prod-vpc" {
  cidr_block = var.vpc_cidr

  tags = {
    Name = "production"
 }
}

#  create the public subnets for ALB
resource "aws_subnet" "public_alb" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.az[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name = "public-alb-subnet-${count.index + 1}"
  }
}

#  create the public subnets for NAT gateway
resource "aws_subnet" "nat_gateway" {
  count             = length(var.nat_subnet_cidrs)
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = var.nat_subnet_cidrs[count.index]
  availability_zone = var.az[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name = "nat-subnet-${count.index + 1}"
  }
}


# create the private subnets for ec2 instance
resource "aws_subnet" "private_app" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.az[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet-${count.index + 1}"
  }
}


# create the database subnets
resource "aws_subnet" "private_db" {
  count             = length(var.db_subnet_cidrs)
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = var.az[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "private-db-subnet-${count.index + 1}"
  }
}

#create subnet group for DB
resource "aws_db_subnet_group" "data_base" {
  name       = "db-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "db-subnet-group"
  }
}


#  create an internet gateway
 resource "aws_internet_gateway" "my-first-gateway" {
  vpc_id = aws_vpc.prod-vpc.id

  tags = {
    Name = "prod-gateway"
  }
}

# create an elastic IP per AZ
resource "aws_eip" "elastic_ip" {
    count   = length(var.az)
    domain   = "vpc"

    tags = {
        Name = "eip-nat-${var.az[count.index]}"
    }
}

# create NAT gateways
resource "aws_nat_gateway" "my-first-nat" {
  count = length(var.az)
  allocation_id = aws_eip.elastic_ip[count.index].id
  subnet_id     = aws_subnet.nat_gateway[count.index].id

  tags = {
    Name = "prod-nat-${var.az[count.index]}"
  }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  # on the Internet Gateway for the VPC.
  depends_on = [aws_internet_gateway.my-first-gateway]
}


#  create public route table
resource "aws_route_table" "public-route" {
  vpc_id = aws_vpc.prod-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my-first-gateway.id
  }

}

# create private route table
resource "aws_route_table" "private_route" {
  count  = 2
  vpc_id = aws_vpc.prod-vpc.id

# without this route, instances in the private subnet cannot reach the Internet, even if the NAT exists.
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.my-first-nat[count.index].id
  }
}


#  Associate ALB public subnets with route table
resource "aws_route_table_association" "alb_public_route" {
  count = length(aws_subnet.public_alb)
  subnet_id      = aws_subnet.public_alb[count.index].id
  route_table_id = aws_route_table.public-route.id
}


#  Associate NAT public subnets with route table
resource "aws_route_table_association" "nat_public_route" {
  count = length(aws_subnet.nat_gateway)
  subnet_id      = aws_subnet.nat_gateway[count.index].id
  route_table_id = aws_route_table.public-route.id
}


# Associate app subnets(private) with route table
resource "aws_route_table_association" "app_private_route" {
  count = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_route[count.index].id
}

# Associate database subnets with route table
resource "aws_route_table_association" "db_route" {
    count = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_route[count.index].id
}


# ALB Security Group
resource "aws_security_group" "ALB-SG" {
  description = "Allow web traffic to the Load Balancer"
  vpc_id      = aws_vpc.prod-vpc.id

}

#inbound rule [internet to the LB]
resource "aws_security_group_rule" "app-alb-ingress" {
  description = "allow http from the internet to the LB"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ALB-SG.id
}


# EC2 Security Group
resource "aws_security_group" "app-server-SG" {
  description = "Allow web traffic from Load Balancer to EC2"
  vpc_id      = aws_vpc.prod-vpc.id

}


#inbound rule for LB to the ec2 instance
resource "aws_security_group_rule" "app-ingress_from_alb" {
    description = "allow traffic from the ALB to the EC2 instance"
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.app-server-SG.id
  source_security_group_id = aws_security_group.ALB-SG.id
}


#outbound rule for web-server
resource "aws_security_group_rule" "app-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app-server-SG.id
}


# Database Security Group
resource "aws_security_group" "rds-sg" {
  description = "Allow traffic to the database"
  vpc_id      = aws_vpc.prod-vpc.id

}

# Create Security Group to allow traffic from ec2 instance to database server
resource "aws_security_group_rule" "db-ingress" {
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = aws_security_group.rds-sg.id
  source_security_group_id = aws_security_group.app-server-SG.id
}





