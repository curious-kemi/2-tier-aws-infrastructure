# Jenkins EC2 Module
module "jenkins-ec2" {
    source = "../../modules/jenkins-ec2"
  ami_value                 = var.ami_value
  key_name                  = var.key_name
  jenkins_subnet_id         = module.vpc.alb_subnets[0]
  jenkins_security_group_id = [module.vpc.jenkins_sg_id]
  jenkins_instance_type     = var.jenkins_instance_type

}


# VPC Module
module "vpc" {
  source               = "../../modules/vpc"
  az                   = var.az
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  nat_subnet_cidrs     = var.nat_subnet_cidrs
  my_ip                = var.my_ip
}
