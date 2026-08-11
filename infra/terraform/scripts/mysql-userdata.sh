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

# Espera o servidor definitivo. O entrypoint sobe um servidor temporário para
# inicializar o banco, e 'mysqladmin ping' já responde a ele — semear nessa fase
# deixa o banco vazio. Só o definitivo aceita TCP, daí a query por --protocol.
for i in $(seq 1 100); do
  if docker exec -e MYSQL_PWD=${db_password} mysql \
    mysql -uroot -h 127.0.0.1 --protocol=TCP -e "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

# semeia (schema idempotente + INSERT IGNORE)
aws s3 cp s3://${bucket}/schema.sql /tmp/schema.sql
aws s3 cp s3://${bucket}/data.sql   /tmp/data.sql
docker cp /tmp/schema.sql mysql:/schema.sql
docker cp /tmp/data.sql   mysql:/data.sql
docker exec -e MYSQL_PWD=${db_password} mysql \
  sh -c "mysql -uroot -h 127.0.0.1 --protocol=TCP ${db_name} < /schema.sql"
docker exec -e MYSQL_PWD=${db_password} mysql \
  sh -c "mysql -uroot -h 127.0.0.1 --protocol=TCP ${db_name} < /data.sql"

# Verificação do seed: com set -e, um banco vazio aborta o user-data aqui, em vez
# de só aparecer depois como erro de SQL na aplicação.
docker exec -e MYSQL_PWD=${db_password} mysql \
  mysql -uroot -h 127.0.0.1 --protocol=TCP -N -e \
  "SELECT COUNT(*) FROM ${db_name}.owners" | grep -qE '^[1-9][0-9]*$'
echo "SEED OK: ${db_name}.owners populado"
