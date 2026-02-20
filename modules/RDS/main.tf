

data "aws_secretsmanager_secret" "database_cred" {
  arn = var.secret_arn_db

}

data "aws_secretsmanager_secret_version" "db_credentials_version" {
  secret_id = data.aws_secretsmanager_secret.database_cred.id  #fixed. it was without "data" before
}


#database instance 
resource "aws_db_instance" "rds_instance" {
  identifier             = "prod-rds-instance"
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage   # disk space
  engine                 = var.engine
  engine_version         = var.engine_version
  storage_type           = var.storage_type
  multi_az               = true
  username               = var.db_username
  password               = data.aws_secretsmanager_secret_version.db_credentials_version.secret_string
  db_subnet_group_name   = var.data_base_subnet_group
  vpc_security_group_ids = [var.db_security_group]
  publicly_accessible    = false
  skip_final_snapshot    = true
  storage_encrypted = true

  tags = {
    Name = "Database instance"

  }
}





