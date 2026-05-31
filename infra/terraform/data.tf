data "aws_caller_identity" "current" {}

# Amazon Linux 2023 (x86_64) mais recente — base das EC2 (mono e MySQL).
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
