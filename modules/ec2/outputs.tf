
output "app_instances" {
  value = aws_instance.ec2_instances[*].id
}