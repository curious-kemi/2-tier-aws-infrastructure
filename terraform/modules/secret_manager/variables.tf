variable "kms_key_id"{
  sensitive = true
  description = "the kms key"
  type = string
}

variable "db_username" {
  type    = string

}