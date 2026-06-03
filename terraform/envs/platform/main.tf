
#App EC2 Module
module "ec2_instance" {
  source                = "../../modules/app-ec2"
  ami_value             = var.ami_value
  instance_type_value   = var.instance_type_value
  app_security_group_id = [module.vpc.ec2_security_group_id]
  app_subnet_ids        = module.vpc.ec2_subnet_ids
  database_secret_id    = module.secret_manager.database_secret_id
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
  kms_key_id             = module.secret_manager.kms_key
  data_base_subnet_group = module.vpc.db_subnet_group
  secret_arn_db          = module.secret_manager.secret_arn
  db_security_group      = module.vpc.db_security_group
  db_password            = module.secret_manager.db_password

}

# Load Balancer Module
module "alb" {
  source              = "../../modules/ALB"
  alb_security_group  = module.vpc.alb_security_group
  alb_subnet_ids      = module.vpc.alb_subnets
  vpc_id              = module.vpc.vpc_id
  target_instance_ids = module.ec2_instance.app_instances
}