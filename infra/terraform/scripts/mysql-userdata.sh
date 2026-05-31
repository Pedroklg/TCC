#!/bin/bash
# Sobe MySQL 8.4 em contêiner (decisão 3) e semeia com o schema/data do PetClinic.
set -euxo pipefail

dnf update -y
dnf install -y docker
command -v aws >/dev/null 2>&1 || dnf install -y awscli
systemctl enable --now docker

docker run -d --name mysql --restart always -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=${db_password} \
  -e MYSQL_DATABASE=${db_name} \
  -e MYSQL_USER=${db_user} \
  -e MYSQL_PASSWORD=${db_password} \
  mysql:8.4 --mysql-native-password=ON

# espera o MySQL aceitar conexões
for i in $(seq 1 60); do
  if docker exec mysql mysqladmin ping -h localhost --silent; then break; fi
  sleep 3
done

# semeia (schema idempotente + INSERT IGNORE)
aws s3 cp s3://${bucket}/schema.sql /tmp/schema.sql
aws s3 cp s3://${bucket}/data.sql   /tmp/data.sql
docker cp /tmp/schema.sql mysql:/schema.sql
docker cp /tmp/data.sql   mysql:/data.sql
docker exec -e MYSQL_PWD=${db_password} mysql sh -c "mysql -uroot ${db_name} < /schema.sql"
docker exec -e MYSQL_PWD=${db_password} mysql sh -c "mysql -uroot ${db_name} < /data.sql"
