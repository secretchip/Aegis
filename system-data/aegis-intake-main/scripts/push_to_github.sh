#!/bin/bash
set -euo pipefail

BASE_DIR="/opt/pdns-intake"
LOG_DIR="${BASE_DIR}/logs"
SCRIPT_NAME="push_to_github"
DATE_STAMP="$(date +%F)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}-${DATE_STAMP}.log"

mkdir -p "${LOG_DIR}"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "${LOG_FILE}"
}

cd "${BASE_DIR}"

log "Starting GitHub push check"

git add .

if git diff --cached --quiet; then
    log "No changes detected. Nothing to commit."
    exit 0
fi

log "Changes detected. Creating commit."
git commit -m "Auto-update pdns-intake $(date '+%F %T')"

log "Pushing to GitHub"
GIT_SSH_COMMAND='ssh -i /root/.ssh/aegis_intake_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
git push origin main

log "Push completed successfully"
