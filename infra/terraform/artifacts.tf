# Bucket de artefatos: jars (mono + serverless) e SQL de seed do MySQL.
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.prefix}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # permite destroy mesmo com objetos
}

resource "aws_s3_object" "mono_jar" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "monolith-exec.jar"
  source = var.monolith_jar_path
  etag   = filemd5(var.monolith_jar_path)
}

resource "aws_s3_object" "lambda_jar" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "serverless-aws.jar"
  source = var.serverless_jar_path
  etag   = filemd5(var.serverless_jar_path)
}

# Schema + seed do PetClinic (do monolito) — o MySQL é semeado no boot.
resource "aws_s3_object" "schema_sql" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "schema.sql"
  source = "../../apps/monolith/src/main/resources/db/mysql/schema.sql"
  etag   = filemd5("../../apps/monolith/src/main/resources/db/mysql/schema.sql")
}

resource "aws_s3_object" "data_sql" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "data.sql"
  source = "../../apps/monolith/src/main/resources/db/mysql/data.sql"
  etag   = filemd5("../../apps/monolith/src/main/resources/db/mysql/data.sql")
}
