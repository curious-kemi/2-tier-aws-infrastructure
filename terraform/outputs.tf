
output "app_instances" {
  value = module.ec2_instance.app_instances
}

output "ec2_private_ips" {
  value = module.ec2_instance.ec2_private_ips
}

output "jenkins_public_ip" {
  value = module.ec2_instance.jenkins_public_ip
}