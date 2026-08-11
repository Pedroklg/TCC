# EC2 do monolito — roda o fat jar (java -jar) apontando para o MySQL compartilhado.
resource "aws_instance" "monolith" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.monolith_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.mono.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name

  user_data = templatefile("${path.module}/scripts/monolith-userdata.sh", {
    bucket      = aws_s3_bucket.artifacts.id
    mysql_host  = aws_instance.mysql.private_ip
    db_name     = var.db_name
    db_user     = var.db_user
    db_password = var.db_password
  })
  user_data_replace_on_change = true

  # O user-data baixa o jar do S3 e instala pacotes via dnf: depende da política
  # da role e da rota de saída, que o Terraform não infere do instance profile.
  depends_on = [
    aws_s3_object.mono_jar,
    aws_instance.mysql,
    aws_iam_role_policy.ec2_s3,
    aws_route_table_association.public
  ]
  tags = { Name = "${var.prefix}-monolith" }
}
