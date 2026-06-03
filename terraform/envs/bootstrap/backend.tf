terraform {
  backend "s3" {
    bucket = "votingapp1-backend"
    key    = "bootstrap/terraform.state"
    region = "us-east-1"
    use_lockfile = true
  }
}
