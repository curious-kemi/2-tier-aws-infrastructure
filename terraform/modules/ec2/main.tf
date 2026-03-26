
# create 2 ec2 instances
resource "aws_instance" "ec2_instances" {
  count = length(var.app_subnet_ids)
  ami           = var.ami_value
  instance_type = var.instance_type_value

  vpc_security_group_ids = var.app_security_group_id
  subnet_id = var.app_subnet_ids[count.index]
  availability_zone = var.az[count.index]

  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name = var.key_name 
 

  tags = {
    Name = "module-ec2-instance-${count.index + 1}"
  }
}

#create an iam role 
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    tag-key = "tag-value"
  }
}

#create the permission policy
resource "aws_iam_role_policy" "ec2_policy" {
  name = "ec2_policy"
  role = aws_iam_role.ec2_role.id

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue*",
        ]
        Effect   = "Allow"
        Resource = var.database_secret_id
      }
    ]
  })
} 

#create an instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.ec2_role.name
}