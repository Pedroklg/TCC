#!/bin/bash
# Provisiona o gerador de carga. Log em /var/log/cloud-init-output.log.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Ambiente congelado durante a campanha: atualização automática no meio de uma
# bateria disputaria o lock do apt e mudaria o sistema sob medição.
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

apt-get update -y
apt-get install -y curl wget gnupg ca-certificates lsb-release unzip git tmux jq python3-venv

# PowerShell 7: os scripts de orquestração são .ps1
wget -qO /tmp/ms-prod.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
dpkg -i /tmp/ms-prod.deb

curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list

curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list

apt-get update -y
apt-get install -y powershell k6 terraform

# AWS CLI v2 (o pacote do apt ainda é a v1)
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Centenas de VUs esgotam portas efêmeras e descritores antes da CPU, o que faria
# do gerador o gargalo justamente no cenário de pico.
cat > /etc/sysctl.d/99-k6.conf <<'SYSCTL'
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1000000
SYSCTL
sysctl --system

cat >> /etc/security/limits.conf <<'LIMITS'
ubuntu soft nofile 65536
ubuntu hard nofile 65536
LIMITS

# Fim do provisionamento + versões das ferramentas (Quadro 2).
{
  echo "provisionado: $(date -Is)"
  pwsh --version
  k6 version
  terraform version | head -1
  /usr/local/bin/aws --version
} > /etc/tcc-runner-ready 2>&1
