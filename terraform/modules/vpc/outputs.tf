output "ec2_subnet_ids" {
  value = aws_subnet.private_app[*].id
}

output "ec2_security_group_id"{
value = aws_security_group.app-server-SG.id
}

output "db_subnet_group" {
    value = aws_db_subnet_group.data_base.name
}

output "alb_security_group" {
    value = aws_security_group.ALB-SG.id
}

output "alb_subnets" {
    value = aws_subnet.public_alb[*].id
}

output "vpc_id" {
  value = aws_vpc.prod-vpc.id
}

output "db_security_group" {
  value = aws_security_group.rds-sg.id
}