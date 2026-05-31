#!/bin/bash
# Instala Java 17 e roda o fat jar do monolito como serviço systemd (profile mysql).
set -euxo pipefail

dnf update -y
dnf install -y java-17-amazon-corretto-headless
command -v aws >/dev/null 2>&1 || dnf install -y awscli

aws s3 cp s3://${bucket}/monolith-exec.jar /opt/app.jar

cat >/etc/systemd/system/petclinic.service <<EOF
[Unit]
Description=PetClinic monolito
After=network.target

[Service]
Environment=SPRING_PROFILES_ACTIVE=mysql,spring-data-jpa
Environment=MYSQL_URL=jdbc:mysql://${mysql_host}:3306/${db_name}?allowPublicKeyRetrieval=true&useSSL=false
Environment=MYSQL_USER=${db_user}
Environment=MYSQL_PASS=${db_password}
ExecStart=/usr/bin/java -jar /opt/app.jar
Restart=always
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now petclinic
