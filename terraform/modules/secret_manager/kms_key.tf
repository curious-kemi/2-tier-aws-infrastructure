resource "aws_kms_key" "db_cmk" {
  description             = "KMS key for RDS"
  enable_key_rotation     = true
  deletion_window_in_days = 15
  is_enabled              = true

  tags = {

  }
}