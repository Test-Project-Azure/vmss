#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ============ CONFIG FROM TERRAFORM (templatefile) =============

AZDO_ORG_URL="${azdo_org_url}"
POOL_NAME="${agent_pool}"
AGENT_VERSION="${agent_version}"
AGENT_USER="${agent_user}"
KEY_VAULT_NAME="${key_vault_name}"
PAT_SECRET_NAME="${agent_pat_secret_name}"
TERRAFORM_VERSION="${terraform_version}"

AGENT_HOME="/home/${AGENT_USER}"
AGENT_DIR="/opt/ado-agent"
WORK_DIR="$AGENT_DIR/_work"

INSTALL_LOG="/var/log/ado-agent-install.log"

zip="terraform_$${TERRAFORM_VERSION}_linux_amd64.zip"
url="https://releases.hashicorp.com/terraform/$${TERRAFORM_VERSION}/terraform_$${TERRAFORM_VERSION}_linux_amd64.zip"

AGENT_CLEANUP_LOG="/var/log/ado-agent-cleanup.log"
OFFLINE_CLEANUP_LOG="/var/log/ado-offline-agent-cleanup.log"

PKG="vsts-agent-linux-x64-${AGENT_VERSION}.tar.gz"
DOWNLOAD_URL="https://download.agent.dev.azure.com/agent/${AGENT_VERSION}/${PKG}"

#============== Helper Functions =============
log() {
  echo "$(date '+%F %T') [$1] $2" | tee -a "$INSTALL_LOG"
}

abort() {
  log ERROR "$1"
  exit 1
}

retry() {
  local attempts="$1"; shift
  local delay="$1"; shift
  local n=0
  while true; do
    if "$@"; then
      return 0
    fi
    n=$((n+1))
    if [[ $n -ge $attempts ]]; then
      return 1
    fi
    sleep "$delay"
  done
}

curl_ado() {
  curl --http1.1 -sS "$@"
}

#======= Azure key Vault Helpers =========
get_kv_access_token() {
  curl -sS \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?resource=https%3A%2F%2Fvault.azure.net&api-version=2018-02-01" \
  | jq -r '.access_token'
}

get_pat_from_kv() {
  local token
  token="$(get_kv_access_token)"

  curl -sS \
    -H "Authorization: Bearer $token" \
    "https://$KEY_VAULT_NAME.vault.azure.net/secrets/$PAT_SECRET_NAME?api-version=7.3" \
  | jq -r '.value'
}

auth_header() {
  local auth_b64
  auth_b64=$(printf ':%s' "$PAT" | base64 | tr -d '\n')
  printf 'Authorization: Basic %s' "$auth_b64"
}

#==== Pre-Checks ======

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root (sudo)." >&2
  exit 1
fi

log INFO "Starting ADO agent install. Pool='$POOL_NAME', Org='$AZDO_ORG_URL'"

export DEBIAN_FRONTEND=noninteractive

log INFO "Waiting for network and DNS..."
retry 10 3 getent hosts dev.azure.com >/dev/null || abort "DNS resolution failed for dev.azure.com"
retry 10 3 getent hosts download.agent.dev.azure.com >/dev/null || abort "DNS resolution failed for download.agent.dev.azure.com"

log INFO "Installing required packages (curl, jq, tar, git, unzip, wget, cronie)..."

if command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
else
  PKG_MGR="yum"
fi

retry 3 5 $PKG_MGR update -y >>"$INSTALL_LOG" 2>&1 || abort "package update failed"
retry 3 5 $PKG_MGR install -y curl jq tar git >>"$INSTALL_LOG" 2>&1 || abort "package install failed"

for cmd in curl jq tar git base64; do
  command -v "$cmd" >/dev/null 2>&1 || abort "$cmd missing"
done

# ============ Install Terraform & Azure CLI (RHEL) ============

install_terraform() {
  set +e

  log INFO "Installing Terraform $TERRAFORM_VERSION..."

  if cd /tmp; then
    if wget -q "$url" -O "$zip"; then
      log INFO "Downloaded $zip, unzipping..."
      if unzip -o "$zip" >>"$INSTALL_LOG" 2>&1; then
        mv -f terraform /usr/local/bin/terraform
        chmod +x /usr/local/bin/terraform
        if terraform -version >>"$INSTALL_LOG" 2>&1; then
          log INFO "Terraform $TERRAFORM_VERSION installed and verified."
        else
          log WARN "Terraform binary present but 'terraform -version' failed."
        fi
      else
        log WARN "Terraform unzip failed, skipping Terraform install."
      fi
    else
      log WARN "Terraform download failed from $url"
    fi

    rm -f "$zip"
  else
    log WARN "Could not cd to /tmp, skipping Terraform install."
  fi

  set -e
}

#==========Install and check Az Cli version =====

install_azure_cli() {

  set +e

  log INFO "Installing latest Azure CLI (RHEL) from Microsoft repo..."

  rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>>"$INSTALL_LOG" || \
    log WARN "Failed to import Microsoft GPG key"

  tee /etc/yum.repos.d/azure-cli.repo > /dev/null << 'EOF'
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

  yum clean all >>"$INSTALL_LOG" 2>&1
  yum makecache >>"$INSTALL_LOG" 2>&1

  if yum install -y azure-cli --disablerepo="*" --enablerepo="azure-cli" >>"$INSTALL_LOG" 2>&1; then
    if az version >>"$INSTALL_LOG" 2>&1; then
      log INFO "Azure CLI installed and verified (latest from Microsoft repo)."
    else
      log WARN "Azure CLI installed but 'az version' failed."
    fi
  else
    log WARN "Azure CLI install failed (Microsoft repo)"
  fi

  set -e
}
log INFO "Installing Terraform $TERRAFORM_VERSION and Azure CLI..."
install_terraform
install_azure_cli
log INFO "Terraform & Azure CLI install steps completed."

# ============ WAIT LOGIC (30 seconds) ============

log INFO "Waiting 30 seconds for Key Vault identity/RBAC propagation..."
sleep 30

log INFO "Fetching PAT from Key Vault '$KEY_VAULT_NAME' secret '$PAT_SECRET_NAME'..."
PAT="$(get_pat_from_kv)"
if [[ -z "$PAT" || "$PAT" == "null" ]]; then
  abort "Failed to retrieve PAT from Key Vault"
fi

# ===============Agent user & directory=============================================

log INFO "Ensuring agent user '$AGENT_USER' and directory '$AGENT_DIR' exist..."
if ! id -u "$AGENT_USER" &>/dev/null; then
  useradd -m -d "$AGENT_HOME" -s /bin/bash "$AGENT_USER"
fi

mkdir -p "$AGENT_DIR" "$WORK_DIR"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_HOME" "$AGENT_DIR"


#=====Download and Configure Agent =====
cd "$AGENT_DIR"
if [[ ! -f "$PKG" ]]; then
  log INFO "Downloading ADO agent from $DOWNLOAD_URL..."
  retry 5 3 curl -sSL -o "$PKG" "$DOWNLOAD_URL" || abort "Agent download failed"
fi

log INFO "Extracting ADO agent..."
tar zxf "$PKG"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_DIR"

NAME="$(hostname)"
export AZP_AGENT_NAME="$NAME"
log INFO "Configuring agent '$NAME' for pool '$POOL_NAME'..."

sudo -u "$AGENT_USER" ./config.sh --unattended \
  --agent "$NAME" \
  --url "$AZDO_ORG_URL" \
  --auth pat \
  --token "$PAT" \
  --pool "$POOL_NAME" \
  --work "$WORK_DIR" \
  --replace \
  --acceptTeeEula >>"$INSTALL_LOG" 2>&1 || abort "Agent config failed"

# =================== CRITICAL FIX ===================
log INFO "Installing agent as service..."
./svc.sh install >>"$INSTALL_LOG" 2>&1

log INFO "Injecting HOME into systemd service..."
AGENT_SERVICE_FILE=$(ls /etc/systemd/system/vsts.agent.*.service)
sed -i "/^\[Service\]/a Environment=HOME=${AGENT_HOME}" "$AGENT_SERVICE_FILE"

systemctl daemon-reexec
systemctl daemon-reload

log INFO "Starting agent service..."
systemctl restart vsts.agent.* >>"$INSTALL_LOG" 2>&1 || abort "Service start failed"

# ===== Git safety =====
sudo -u "$AGENT_USER" git config --global --add safe.directory '*'

log INFO "ADO agent installed successfully with HOME fixed."

#==== Pre Vm Shutodonw cleanup=========
log INFO "Installing per-VM agent cleanup script and systemd unit (on shutdown)..."

cat >/usr/local/bin/ado-agent-cleanup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/ado-agent-cleanup.log"
AGENT_DIR="/opt/ado-agent"
AGENT_USER="__AGENT_USER__"
PAT="__PAT_PLACEHOLDER__"

log(){ echo "$(date '+%F %T') [$1] $2" | tee -a "$LOG_FILE"; }

log INFO "Starting agent cleanup on shutdown..."

if [[ ! -d "$AGENT_DIR" ]]; then
  log INFO "Agent directory '$AGENT_DIR' not found; nothing to do."
  exit 0
fi

cd "$AGENT_DIR"

log INFO "Stopping agent service..."
./svc.sh stop >>"$LOG_FILE" 2>&1 || log WARN "Service stop failed (maybe already stopped)"

log INFO "Removing agent registration from Azure DevOps (as '$AGENT_USER')..."
if ! sudo -u "$AGENT_USER" ./config.sh remove --unattended --auth pat --token "$PAT" >>"$LOG_FILE" 2>&1; then
  log WARN "Agent remove failed – may already be removed or network down."
else
  log INFO "Agent successfully removed from Azure DevOps."
fi

log INFO "Agent cleanup completed."
exit 0
EOF

sed -i "s/__AGENT_USER__/$AGENT_USER/g" /usr/local/bin/ado-agent-cleanup.sh
ESCAPED_PAT=$(printf '%s\n' "$PAT" | sed 's/[&/]/\\&/g')
sed -i "s/__PAT_PLACEHOLDER__/$ESCAPED_PAT/g" /usr/local/bin/ado-agent-cleanup.sh

chmod +x /usr/local/bin/ado-agent-cleanup.sh

cat >/etc/systemd/system/ado-agent-cleanup.service <<'EOF'
[Unit]
Description=Azure DevOps Agent Cleanup on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target poweroff.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/ado-agent-cleanup.sh
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ado-agent-cleanup.service
systemctl start ado-agent-cleanup.service || true

log INFO "Per-VM shutdown cleanup installed."

# ===== Pool wide offline aent cleanup=====

log INFO "Installing pool-wide offline agent cleanup script and cron job..."

cat >/usr/local/bin/ado-offline-agent-cleaner.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ORG_URL="__ORG_URL__"
POOL_NAME="__POOL_NAME__"
PAT="__PAT_PLACEHOLDER__"

LOG_FILE="/var/log/ado-offline-agent-cleanup.log"

# Empty prefix => act on ALL agents in the pool
AGENT_NAME_PREFIX=""

log() { echo "$(date '+%F %T') [$1] $2" | tee -a "$LOG_FILE"; }

auth_header() {
  local auth_b64
  auth_b64=$(printf ':%s' "$PAT" | base64 | tr -d '\n')
  printf 'Authorization: Basic %s' "$auth_b64"
}

curl_ado() {
  curl --http1.1 -sS "$@"
}

log INFO "Starting offline agent cleanup for pool '$POOL_NAME'..."

for cmd in curl jq base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log ERROR "Missing required command: $cmd"
    exit 1
  fi
done

POOL_JSON=$(curl_ado \
  -H "$(auth_header)" \
  "$ORG_URL/_apis/distributedtask/pools?poolName=$POOL_NAME&api-version=7.1-preview.1") || {
    log ERROR "Failed to query pool list from Azure DevOps"
    exit 1
  }

POOL_ID=$(echo "$POOL_JSON" | jq -r '.value[0].id')

if [[ -z "$POOL_ID" || "$POOL_ID" == "null" ]]; then
  log ERROR "Could not find pool '$POOL_NAME' in org '$ORG_URL'"
  log ERROR "Raw response: $POOL_JSON"
  exit 1
fi

log INFO "Pool '$POOL_NAME' resolved to id=$POOL_ID"

AGENTS_JSON=$(curl_ado \
  -H "$(auth_header)" \
  "$ORG_URL/_apis/distributedtask/pools/$POOL_ID/agents?includeAssignedRequest=true&api-version=7.1-preview.1") || {
    log ERROR "Failed to fetch agents for pool id=$POOL_ID"
    exit 1
  }

COUNT_DELETED=0
COUNT_SKIPPED=0

echo "$AGENTS_JSON" | jq -c '.value[]' | while IFS= read -r agent; do
  ID=$(echo "$agent"   | jq -r '.id')
  NAME=$(echo "$agent" | jq -r '.name')
  STATUS=$(echo "$agent" | jq -r '.status')
  ENABLED=$(echo "$agent" | jq -r '.enabled')

  if [[ -n "$AGENT_NAME_PREFIX" && "$NAME" != "$AGENT_NAME_PREFIX"* ]]; then
    log INFO "Skipping agent id=$ID name=$NAME (prefix mismatch)"
    COUNT_SKIPPED=$((COUNT_SKIPPED+1))
    continue
  fi

  if [[ "$ENABLED" == "true" && "$STATUS" == "offline" ]]; then
    log INFO "Deleting offline agent id=$ID name=$NAME status=$STATUS enabled=$ENABLED"
    if curl_ado -X DELETE \
        -H "$(auth_header)" \
        "$ORG_URL/_apis/distributedtask/pools/$POOL_ID/agents/$ID?api-version=7.1-preview.1" \
        >/dev/null; then
      log INFO "Successfully deleted agent id=$ID name=$NAME"
      COUNT_DELETED=$((COUNT_DELETED+1))
    else
      log ERROR "Failed to delete agent id=$ID name=$NAME"
    fi
  else
    log INFO "Keeping agent id=$ID name=$NAME status=$STATUS enabled=$ENABLED"
    COUNT_SKIPPED=$((COUNT_SKIPPED+1))
  fi
done

log INFO "Cleanup run completed. Deleted=$COUNT_DELETED, Skipped=$COUNT_SKIPPED"
exit 0
EOF

sed -i "s|__ORG_URL__|$AZDO_ORG_URL|g" /usr/local/bin/ado-offline-agent-cleaner.sh
sed -i "s|__POOL_NAME__|$POOL_NAME|g" /usr/local/bin/ado-offline-agent-cleaner.sh
sed -i "s/__PAT_PLACEHOLDER__/$ESCAPED_PAT/g" /usr/local/bin/ado-offline-agent-cleaner.sh

chmod +x /usr/local/bin/ado-offline-agent-cleaner.sh
touch "$OFFLINE_CLEANUP_LOG"

CRON_LINE="*/5 * * * * /usr/bin/env bash /usr/local/bin/ado-offline-agent-cleaner.sh >> $OFFLINE_CLEANUP_LOG 2>&1"

( crontab -u root -l 2>/dev/null | grep -v 'ado-offline-agent-cleaner.sh' || true; echo "$CRON_LINE" ) | crontab -u root -

unset PAT
log INFO "Agent '$NAME' installed, per-VM shutdown cleanup + pool-wide offline cleanup configured."
