#create an ec2 instance to host jenkins
# Jenkins server
resource "aws_instance" "jenkins" {
  ami                    = var.ami_value
  instance_type          = var.jenkins_instance_type
  subnet_id              = var.jenkins_subnet_id
  vpc_security_group_ids = var.jenkins_security_group_id
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name
  key_name               = var.key_name

  tags = {
    Name = "jenkins-server"
  }
}

#create an iam role for the jenkins
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-role"

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

#create the permission policy for jenkins
resource "aws_iam_role_policy" "jenkins_policy" {
  name = "jenkins_policy"
  role = aws_iam_role.jenkins_role.id
  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      {
        # Rule 1 - all resources
        Action = [
          "ec2:DescribeInstances",
        "ec2:DescribeTags"]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
     
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.env}/ssh/*"
    }]

     Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:ListSecrets"
          
    }]
  })
}

#create an instance profile for the jenkins
resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins_profile"
  role = aws_iam_role.jenkins_role.name
}

