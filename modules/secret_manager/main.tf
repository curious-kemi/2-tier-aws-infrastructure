
#generates random password
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

#Secret manager for database
resource "aws_secretsmanager_secret" "database_cred" {
  name        = "rds_credentials"
  description = "Credentials for the Database"
  kms_key_id  = var.kms_key_id

  tags = {
    Name = "rds-secret-manager"
  }
}

#secret manager - secret version
resource "aws_secretsmanager_secret_version" "db_credentials_version" {
  secret_id = aws_secretsmanager_secret.database_cred.id
  secret_string = random_password.db_password.result
    }
  



 