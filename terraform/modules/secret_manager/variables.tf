variable "kms_key_id"{
  sensitive = true
  description = "the kms key"
  type = string
}