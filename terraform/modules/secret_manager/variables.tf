variable "kms_key_id" {
  sensitive   = true
  description = "the kms key"
  type        = string
}

variable "db_username" {
  type = string

}

variable "db_host" {
  type = string
  description = "host"

}

variable "db_port" {
  type = string
  description = "port"

}