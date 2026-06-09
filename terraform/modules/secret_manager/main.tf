
#generates random password (app)
resource "random_password" "db_password" {
  length           = 16
  special          = false
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

#Secret manager for database 
resource "aws_secretsmanager_secret" "database_cred" {
  name                    = "db_credentials"
  description             = "Credentials for the Database"
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = 7

  tags = {
    Name = "rds-secret-manager"
  }
}

#secret manager - secret version (db credentials)
resource "aws_secretsmanager_secret_version" "db_credentials_version" {
  secret_id = aws_secretsmanager_secret.database_cred.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    dbname   = "votingapp"
  })
}


/* create a key pair for ansible to be able to ssh into ec2 */

#first, create the private key
resource "tls_private_key" "ansible" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

#Use the aws_key_pair resource to upload the generated public key to your AWS account
resource "aws_key_pair" "ansible" {
  key_name   = "ansible-key"
  public_key = tls_private_key.ansible.public_key_openssh
}

# store the private key in secret manager
resource "aws_secretsmanager_secret" "ansible_key" {
  name = "prod/ssh/ansible-key"
  description = "Private key for application access"

  # these tags will help jenkins identity the private key in secret manager
  tags = {
  "jenkins:credentials:type"     = "sshUserPrivateKey"
  "jenkins:credentials:username" = "ubuntu" 

  }
}

# store the private key in secret manager
resource "aws_secretsmanager_secret_version" "ansible_key" {
  secret_id     = aws_secretsmanager_secret.ansible_key.id
  secret_string = tls_private_key.ansible.private_key_pem
}


 