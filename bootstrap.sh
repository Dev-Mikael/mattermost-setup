#!/usr/bin/env bash
# bootstrap.sh — Master Automation Script
# =========================================
# ONE command to deploy Mattermost end-to-end via GitOps.
#
# Usage:
#   1. cp .env.example .env && nano .env   # fill in ALL values, inc. SSH_KEY_PATH
#   2. (kubeadm) place your .pem key in the repo folder or point SSH_KEY_PATH to it
#   3. bash bootstrap.sh
#
# For kubeadm: bootstrap.sh SSHes into the server automatically — no manual
# login required. It runs kubeadm, pulls kubeconfig, and continues end-to-end.
# For kind: Docker must be running locally.
# =========================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Inline colours (no lib dependency yet)
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n${BOLD}  $*${NC}\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │         Mattermost GitOps Bootstrap v2               │"
echo "  │  kubeadm / kind  +  FluxCD  +  Sealed Secrets        │"
echo "  └──────────────────────────────────────────────────────┘"
echo -e "${NC}"

# Validate .env exists
if [[ ! -f ".env" ]]; then
  log_error ".env not found!"
  echo ""
  echo "  Steps to fix:"
  echo "    1. cp .env.example .env"
  echo "    2. nano .env          (fill in all values)"
  echo "    3. bash bootstrap.sh  (re-run)"
  exit 1
fi

source ".env"
log_ok ".env loaded (DOMAIN=${DOMAIN}, CLUSTER_TYPE=${CLUSTER_TYPE})"

# Make all scripts executable
chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

# ── Step 1: Tools ─────────────────────────────────────────────
log_section "Step 1/5 — Install Required Tools"
bash scripts/01-install-tools.sh

# ── Step 2: Cluster ───────────────────────────────────────────
log_section "Step 2/5 — Kubernetes Cluster"

case "${CLUSTER_TYPE:-kubeadm}" in
  kind)
    log_info "CLUSTER_TYPE=kind → creating local kind cluster"
    if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
      log_error "Docker is not running. Start Docker Desktop first."
      exit 1
    fi
    bash scripts/02a-create-cluster-kind.sh
    # Reload .env to pick up METALLB_IP_RANGE set by 02a
    source ".env"
    ;;
  kubeadm)
    # ── Re-run guard: cluster already up (e.g. re-running bootstrap) ──────────
    if kubectl cluster-info > /dev/null 2>&1; then
      log_ok "Existing kubeadm cluster detected — skipping remote provisioning"
      if [[ -z "${METALLB_IP_RANGE:-}" ]]; then
        log_error "METALLB_IP_RANGE is empty. Set it to your server public IP, e.g: ${SERVER_IP}/32"
        exit 1
      fi
    else
      # ── First run: SSH into server, run kubeadm setup, pull kubeconfig back ──
      log_info "Provisioning ${SERVER_IP} automatically via SSH..."
      bash scripts/02b-remote-setup.sh
      # Reload .env — 02b-remote-setup.sh writes METALLB_IP_RANGE back into it
      source ".env"
    fi
    ;;
  *)
    log_error "Unknown CLUSTER_TYPE='${CLUSTER_TYPE}'. Use 'kind' or 'kubeadm'."
    exit 1
    ;;
esac

# ── Step 3: Bootstrap Flux ────────────────────────────────────
log_section "Step 3/5 — Bootstrap FluxCD"
bash scripts/03-bootstrap-flux.sh

# ── Step 4: Seal Secrets + Push Apps ─────────────────────────
log_section "Step 4/5 — Seal Secrets & Deploy Apps"
bash scripts/04-wait-and-seal.sh

# ── Step 5: Verify ────────────────────────────────────────────
log_section "Step 5/5 — Verify Deployment"
bash scripts/05-verify.sh

# ── Done ──────────────────────────────────────────────────────
source ".env"   # reload in case anything was updated

log_section "Bootstrap Complete!"
echo ""
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  echo -e "${BOLD}  Local Access (kind):${NC}"
  echo "    1. Add to /etc/hosts:  ${INGRESS_IP}  ${DOMAIN}"
  echo "    2. Open browser:       http://${DOMAIN}"
  echo ""
  echo "  Note: HTTPS requires a real server with a public IP."
  echo "        When you get your server, set CLUSTER_TYPE=kubeadm"
  echo "        and SERVER_IP=<your-ip> in .env, then re-run."
else
  echo -e "${BOLD}  On-Prem Access (kubeadm):${NC}"
  echo "    1. Add DNS A record:  ${DOMAIN}  →  ${SERVER_IP}"
  echo "    2. Wait ~2 min for cert-manager to issue TLS cert"
  echo "    3. Open browser:      https://${DOMAIN}"
fi
echo ""
echo -e "${BOLD}  Watch deployment live:${NC}"
echo "    kubectl get pods -n mattermost --watch"
echo "    flux get all -A"
echo ""
echo -e "${GREEN}${BOLD}  Mattermost is deploying! 🎉${NC}"
echo ""
