/*create a data source so that the platform module will be able to retrieve
data from the bootstrap module state file */

data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket = "votingapp1-backend"
    key    = "bootstrap/terraform.state"
    region = "us-east-1"
  }
}


# create a dynamic lookup instead of hardcoding the ami ID
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}