data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket = "votingapp1-backend"
    key    = "bootstrap/terraform.state"
    region = "us-east-1"
  }
}
