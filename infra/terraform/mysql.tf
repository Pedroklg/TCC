# EC2 com MySQL 8.4 em contêiner — banco compartilhado pelas 3 arquiteturas.
resource "aws_instance" "mysql" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.mysql_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.mysql.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name

  user_data = templatefile("${path.module}/scripts/mysql-userdata.sh", {
    bucket      = aws_s3_bucket.artifacts.id
    db_name     = var.db_name
    db_user     = var.db_user
    db_password = var.db_password
  })
  user_data_replace_on_change = true

  depends_on = [aws_s3_object.schema_sql, aws_s3_object.data_sql]
  tags       = { Name = "${var.prefix}-mysql" }
}
