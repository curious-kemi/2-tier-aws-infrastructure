output "jenkins_public_ip" {
  value = module.jenkins-ec2.jenkins_public_ip
}

 # output all the data that needs the configurations from the vpc module
output "app_security_group_id" {
    value = module.vpc.ec2_security_group_id
}

# output all the data that needs the configurations from the vpc module
output "app_subnet_ids" {
    value = module.vpc.ec2_subnet_ids
}

# output all the data that needs the configurations from the vpc module
output "data_base_subnet_group" {
    value = module.vpc.db_subnet_group
}

# output all the data that needs the configurations from the vpc module
output "db_security_group" {
    value = module.vpc.db_security_group
}

# output all the data that needs the configurations from the vpc module
output "alb_security_group" {
    value = module.vpc.alb_security_group
}

# output all the data that needs the configurations from the vpc module
output "alb_subnet_ids" {
    value = module.vpc.alb_subnets
}

# output all the data that needs the configurations from the vpc module
output "vpc_id" {
    value = module.vpc.vpc_id
}

