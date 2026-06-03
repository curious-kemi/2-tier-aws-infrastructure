
#App EC2 Module
module "ec2_instance" {
  source                = "../../modules/app-ec2"
  ami_value             = var.ami_value
  instance_type_value   = var.instance_type_value
  app_security_group_id = data.terraform_remote_state.bootstrap.outputs.app_security_group_id
  app_subnet_ids        = data.terraform_remote_state.bootstrap.outputs.app_subnet_ids
  database_secret_id    = data.terraform_remote_state.bootstrap.outputs.database_secret_id
  az                    = var.az
  key_name              = var.key_name
}

# Secret Manager Module
module "secret_manager" {
  source      = "../../modules/secret_manager"
  kms_key_id  = module.secret_manager.kms_key
  db_username = var.db_username
}

# Database Module
module "rds" {
  source                 = "../../modules/RDS"
  db_username            = var.db_username
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage # disk space
  engine                 = var.engine
  engine_version         = var.engine_version
  storage_type           = var.storage_type
  kms_key_id             = data.terraform_remote_state.bootstrap.outputs.kms_key_id
  data_base_subnet_group = data.terraform_remote_state.bootstrap.outputs.data_base_subnet_group
  secret_arn_db          = data.terraform_remote_state.bootstrap.outputs.secret_arn_db
  db_security_group      = data.terraform_remote_state.bootstrap.outputs.db_security_group
  db_password            = data.terraform_remote_state.bootstrap.outputs.db_password

}

# Load Balancer Module
module "alb" {
  source              = "../../modules/ALB"
  alb_security_group  = data.terraform_remote_state.bootstrap.outputs.alb_security_group
  alb_subnet_ids      = data.terraform_remote_state.bootstrap.outputs.alb_subnet_ids
  vpc_id              = data.terraform_remote_state.bootstrap.outputs.vpc_id
  target_instance_ids = data.terraform_remote_state.bootstrap.outputs.app_instances
}