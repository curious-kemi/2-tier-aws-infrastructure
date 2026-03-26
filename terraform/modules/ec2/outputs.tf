
output "app_instances" {
  value = aws_instance.ec2_instances[*].id
}

output "ec2_private_ips" {
  value = aws_instance.ec2_instances[*].private_ip
}