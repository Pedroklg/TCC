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

# CloudWatch Agent: publica a memória da EC2 (CWAgent/mem_used_percent) para a
# captura de recursos (§3.5 — cloudwatch-capture.ps1). A CPU já vem do AWS/EC2.
dnf install -y amazon-cloudwatch-agent
cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'JSON'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "metrics_collected": { "mem": { "measurement": ["mem_used_percent"] } }
  }
}
JSON
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
