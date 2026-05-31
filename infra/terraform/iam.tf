# Papel das EC2 (monolito e MySQL): apenas leitura do bucket de artefatos.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_s3" {
  name               = "${var.prefix}-ec2-s3"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "ec2_s3" {
  name = "${var.prefix}-ec2-s3-read"
  role = aws_iam_role.ec2_s3.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_s3" {
  name = "${var.prefix}-ec2-s3"
  role = aws_iam_role.ec2_s3.name
}
