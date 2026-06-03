# Jenkins EC2 Module
module "jenkins-ec2" {
    source = "../../modules/jenkins-ec2"
  ami_value                 = var.ami_value
  key_name                  = var.key_name
  jenkins_subnet_id         = module.vpc.alb_subnets[0]
  jenkins_security_group_id = [module.vpc.jenkins_sg_id]
  jenkins_instance_type     = var.jenkins_instance_type

}


