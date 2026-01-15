#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
# ================= TERRAFORM INPUTS =================
AZDO_ORG_URL="${azdo_org_url}"
POOL_NAME="${agent_pool}"
AGENT_VERSION="${agent_version}"
AGENT_USER="${agent_user}"
KEY_VAULT_NAME="${key_vault_name}"
PAT_SECRET_NAME="${agent_pat_secret_name}"
TERRAFORM_VERSION="${terraform_version}"

# ================= CONSTANTS =================
AGENT_DIR="/opt/ado-agent"
WORK_DIR="$AGENT_DIR/_work"
INSTALL_LOG="/var/log/ado-agent-install.log"
OFFLINE_CLEANUP_LOG="/var/log/ado-offline-agent-cleanup.log"

PKG="vsts-agent-linux-x64-$${AGENT_VERSION}.tar.gz"
DOWNLOAD_URL="https://download.agent.dev.azure.com/agent/$${AGENT_VERSION}/$${PKG}"

TF_ZIP="terraform_$${TERRAFORM_VERSION}_linux_amd64.zip"
TF_URL="https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/$${TF_ZIP}"

# ================= FUNCTIONS =================
log() {
  echo "$(date '+%F %T') [$1] $2" | tee -a "$INSTALL_LOG"
}

abort() {
  log ERROR "$1"
  exit 1
}

retry() {
  local attempts=$1 delay=$2
  shift 2
  local n=0
  until "$@"; do
    ((n++))
    [[ $n -ge $attempts ]] && return 1
    sleep "$delay"
  done
}

curl_ado() {
  curl --http1.1 -sS "$@"
}

auth_header() {
  printf 'Authorization: Basic %s' \
    "$(printf ':%s' "$${PAT}" | base64 | tr -d '\n')"
}

# ================= ROOT CHECK =================
[[ "$(id -u)" -eq 0 ]] || abort "Run as root"

# ================= NETWORK =================
log INFO "Waiting for network & DNS..."
retry 10 3 getent hosts dev.azure.com >/dev/null || abort "DNS failed: dev.azure.com"
retry 10 3 getent hosts download.agent.dev.azure.com >/dev/null || abort "DNS failed: agent download"

# ================= OS PACKAGES =================
log INFO "Installing OS packages..."
yum install -y git curl jq unzip wget tar cronie >/dev/null

# ================= TERRAFORM =================
log INFO "Installing Terraform $${TERRAFORM_VERSION}"
cd /tmp
wget -q "$TF_URL" -O "$TF_ZIP"
unzip -o "$TF_ZIP" >/dev/null
mv terraform /usr/local/bin/terraform
chmod +x /usr/local/bin/terraform
ln -sf /usr/local/bin/terraform /usr/bin/terraform
terraform -version >>"$INSTALL_LOG" 2>&1
rm -f "$TF_ZIP"


# ================= AZURE CLI =================
log INFO "Installing Azure CLI..."
rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat >/etc/yum.repos.d/azure-cli.repo <<EOF
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

yum clean all >/dev/null
yum install -y azure-cli >/dev/null
az version >>"$INSTALL_LOG" 2>&1

# ================= KEY VAULT / MSI =================
get_pat() {
  TOKEN=$(curl -sS -H "Metadata:true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?resource=https://vault.azure.net&api-version=2018-02-01" \
    | jq -r .access_token)

  curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://$${KEY_VAULT_NAME}.vault.azure.net/secrets/$${PAT_SECRET_NAME}?api-version=7.3" \
    | jq -r .value
}

log INFO "Waiting for MSI propagation..."
sleep 10

PAT="$(get_pat)"
[[ -n "$${PAT}" && "$${PAT}" != "null" ]] || abort "PAT fetch failed"

log INFO "Validating PAT..."
curl_ado -H "$(auth_header)" \
  "$AZDO_ORG_URL/_apis/projects?api-version=7.0" >/dev/null || abort "PAT invalid"

# ================= AGENT INSTALL =================
log INFO "Creating agent user & directory..."
id "$AGENT_USER" &>/dev/null || useradd --system -m -d "$AGENT_DIR" -s /bin/bash "$AGENT_USER"

mkdir -p "$WORK_DIR"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_DIR"
cd "$AGENT_DIR"

log INFO "Creating Terraform runtime directories..."

mkdir -p "$AGENT_DIR/.terraform.d/plugin-cache"
mkdir -p "$AGENT_DIR/.azure"

chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/.terraform.d" "$AGENT_DIR/.azure"
chmod -R 700 "$AGENT_DIR/.terraform.d" "$AGENT_DIR/.azure"

log INFO "Downloading Azure DevOps agent..."
retry 5 3 curl -sSL -o "$PKG" "$DOWNLOAD_URL" || abort "Agent download failed"
tar zxf "$PKG"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_DIR"

AGENT_NAME="$(hostname)"

log INFO "Configuring agent..."
sudo -u "$AGENT_USER" -H env HOME="$AGENT_DIR" ./config.sh \
  --unattended \
  --agent "$AGENT_NAME" \
  --url "$AZDO_ORG_URL" \
  --auth pat \
  --token "$${PAT}" \
  --pool "$POOL_NAME" \
  --work "$WORK_DIR" \
  --replace \
  --acceptTeeEula >>"$INSTALL_LOG" 2>&1

./svc.sh install >>"$INSTALL_LOG" 2>&1
./svc.sh start   >>"$INSTALL_LOG" 2>&1

# ================= SYSTEMD ENV FIX  =================
AGENT_SERVICE=$(systemctl list-units --type=service | grep vsts.agent | awk '{print $1}')

mkdir -p /etc/systemd/system/$AGENT_SERVICE.d

cat >/etc/systemd/system/$AGENT_SERVICE.d/env.conf <<EOF
[Service]
Environment=HOME=$AGENT_DIR
Environment=GIT_CONFIG_GLOBAL=$AGENT_DIR/.gitconfig
Environment=AZURE_CONFIG_DIR=$AGENT_DIR/.azure
Environment=TF_PLUGIN_CACHE_DIR=$AGENT_DIR/.terraform.d/plugin-cache
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl restart "$AGENT_SERVICE"

# ================= HOME / ENV FIX =================
cat >"$AGENT_DIR/.env" <<EOF
HOME=$AGENT_DIR
GIT_CONFIG_GLOBAL=$AGENT_DIR/.gitconfig
AZURE_CONFIG_DIR=$AGENT_DIR/.azure
TF_PLUGIN_CACHE_DIR=$AGENT_DIR/.terraform.d/plugin-cache
EOF

chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/.env"
chmod 600 "$AGENT_DIR/.env"
./svc.sh restart >>"$INSTALL_LOG" 2>&1

# ================= SHUTDOWN CLEANUP =================
cat >/usr/local/bin/ado-agent-cleanup.sh <<EOF
#!/usr/bin/env bash
cd "$AGENT_DIR" || exit 0

if [[ -f "$AGENT_DIR/.pat" ]]; then
  PAT=\$(cat "$AGENT_DIR/.pat")
  ./svc.sh stop || true
  ./config.sh remove --unattended --auth pat --token "\$PAT" || true
else
  ./svc.sh stop || true
fi
EOF

chmod +x /usr/local/bin/ado-agent-cleanup.sh

# ================= OFFLINE AGENT CLEANER =================

cat >/usr/local/bin/ado-offline-agent-cleaner.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

exec >> "$OFFLINE_CLEANUP_LOG" 2>&1
set -x

ORG_URL="$AZDO_ORG_URL"
POOL_NAME="$POOL_NAME"
PAT_FILE="$AGENT_DIR/.pat"

auth_header() {
  printf 'Authorization: Basic %s' \
    "\$(printf ':%s' "\$(cat "\$PAT_FILE")" | base64 | tr -d '\n')"
}

curl_ado() { curl --http1.1 -sS "\$@"; }

POOL_ID=\$(curl_ado -H "\$(auth_header)" \
  "\$ORG_URL/_apis/distributedtask/pools?poolName=\$POOL_NAME&api-version=7.1-preview.1" \
  | jq -r '.value[0].id')

if [[ -z "\$POOL_ID" || "\$POOL_ID" == "null" ]]; then
  echo "ERROR: Pool ID not found for pool \$POOL_NAME"
  exit 1
fi

curl_ado -H "\$(auth_header)" \
  "\$ORG_URL/_apis/distributedtask/pools/\$POOL_ID/agents?includeAssignedRequest=true&api-version=7.1-preview.1" \
  | jq -c '.value[]' | while read -r agent; do
    ID=\$(jq -r '.id' <<<"\$agent")
    STATUS=\$(jq -r '.status' <<<"\$agent")
    ENABLED=\$(jq -r '.enabled' <<<"\$agent")
    ASSIGNED=\$(jq -r '.assignedRequest' <<<"\$agent")

    if [[ "\$ENABLED" == "true" && "\$STATUS" == "offline" && ( "\$ASSIGNED" == "null" || "\$ASSIGNED" == "{}" ) ]]; then
      echo "Deleting offline agent ID=\$ID"
      curl_ado -X DELETE -H "\$(auth_header)" \
        "\$ORG_URL/_apis/distributedtask/pools/\$POOL_ID/agents/\$ID?api-version=7.1-preview.1"
    fi
done
EOF


chmod +x /usr/local/bin/ado-offline-agent-cleaner.sh

echo "$PAT" >"$AGENT_DIR/.pat"
chmod 600 "$AGENT_DIR/.pat"

(crontab -l 2>/dev/null | grep -v ado-offline-agent-cleaner || true
 echo "*/5 * * * * /usr/local/bin/ado-offline-agent-cleaner.sh >> $OFFLINE_CLEANUP_LOG 2>&1") | crontab -

unset PAT
log INFO "ADO agent installed successfully and ONLINE"
