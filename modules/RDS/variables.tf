variable "db_username" {
  type    = string
  sensitive = true
  
}

variable "allocated_storage" {
  description = "the amount of storage to allocate"
  type = number
  sensitive = true
  
  
}

variable "storage_type" {
  description = "value"
  type = string
 
}

variable "engine" {
  description = "the engine for the database"
  type = string
  
}

variable "engine_version" {
  description = "database engine version"
  type = string
 
}

variable "instance_class" {
  description = "the instance class for the database"
  type = string
}

variable "kms_key_id"{
  sensitive = true
  description = "the kms key"
  type = string
}

variable "data_base_subnet_group" {
   description = "database subnet group"
}

variable "secret_arn_db" {
  description = "database secret ARN"
}

variable "db_security_group" {
  description = "Database Security Group"
}

