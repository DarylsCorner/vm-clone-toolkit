#!/usr/bin/env bash
# Validate Azure Enhanced Monitoring Extension for SAP (MonitorX64Linux) on a single VM
# Usage:
#   sudo bash validate_aem_monitorx64linux.sh
#
# Optional environment variables:
#   AEM_WAAGENT_DIR=/var/lib/waagent
#   AEM_LEGACY_DIR=/var/lib/AzureEnhancedMonitor
#   AEM_ENDPOINT_PORT=11812
#
# Exit codes:
#   0 = All critical checks passed
#   1 = One or more critical checks failed

set -euo pipefail

# ---------- Config ----------
AEM_WAAGENT_DIR="${AEM_WAAGENT_DIR:-/var/lib/waagent}"
AEM_LEGACY_DIR="${AEM_LEGACY_DIR:-/var/lib/AzureEnhancedMonitor}"
AEM_ENDPOINT_PORT="${AEM_ENDPOINT_PORT:-11812}"
LOOPBACK="127.0.0.1"
AEM_PUBLISHER="Microsoft.AzureCAT.AzureEnhancedMonitoring"
AEM_TYPE="MonitorX64Linux"

# ---------- Internal state ----------
declare -A RESULTS
RESULTS=(
  [files_present]="FAIL"
  [manifest_present]="FAIL"
  [process_running]="FAIL"
  [endpoint_ok]="SKIP"
  [legacy_perf_ok]="SKIP"
  [error_log_clean]="SKIP"
  [saposcol_installed]="SKIP"
  [enhanced_access_true]="SKIP"
)

STATUS_COLOR_PASS="\e[32m"
STATUS_COLOR_FAIL="\e[31m"
STATUS_COLOR_SKIP="\e[33m"
STATUS_COLOR_RESET="\e[0m"

log()  { printf "%s\n" "$*"; }
ok()   { printf "${STATUS_COLOR_PASS}✔ %s${STATUS_COLOR_RESET}\n" "$*"; }
warn() { printf "${STATUS_COLOR_SKIP}⚠ %s${STATUS_COLOR_RESET}\n" "$*"; }
err()  { printf "${STATUS_COLOR_FAIL}✖ %s${STATUS_COLOR_RESET}\n" "$*"; }

hr() { printf -- "------------------------------------------------------------\n"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- Check 1: Extension files present ----------
check_files_present() {
  hr
  log "Checking extension files under: ${AEM_WAAGENT_DIR}"
  local pattern="${AEM_PUBLISHER}.${AEM_TYPE}"
  local found_files
  found_files=$(ls -1 "${AEM_WAAGENT_DIR}" 2>/dev/null | grep -i "${pattern}" || true)

  if [[ -n "${found_files}" ]]; then
    ok "Extension artifacts found in waagent dir:"
    printf "%s\n" "${found_files}" | sed 's/^/   - /'
    RESULTS[files_present]="PASS"
  else
    err "No ${AEM_PUBLISHER}.${AEM_TYPE} artifacts found in ${AEM_WAAGENT_DIR}"
  fi

  # Look for manifest or version files
  local manifest
  manifest=$(grep -ril "${AEM_TYPE}" "${AEM_WAAGENT_DIR}" 2>/dev/null || true)
  if [[ -n "${manifest}" ]]; then
    ok "Found manifest/version-related files:"
    printf "%s\n" "${manifest}" | sed 's/^/   - /'
    RESULTS[manifest_present]="PASS"
  else
    warn "Could not locate manifest/version files; continuing."
  fi
}

# ---------- Check 2: Process/daemon running ----------
check_process_running() {
  hr
  log "Checking for running extension processes..."
  # Heuristics: look for publisher/type keywords; adjust if your process name differs.
  local ps_hits
  ps_hits=$(ps aux | grep -Ei "${AEM_TYPE}|AzureEnhancedMonitoring|azure4sap" | grep -v grep || true)

  if [[ -n "${ps_hits}" ]]; then
    ok "Detected extension-related running process(es):"
    printf "%s\n" "${ps_hits}" | sed 's/^/   > /'
    RESULTS[process_running]="PASS"
  else
    err "No obvious extension process found. If you use systemd, ensure service is active."
  fi
}

# ---------- Check 3: New endpoint (Python 3-based builds) ----------
check_local_endpoint() {
  hr
  log "Probing local metrics endpoint (newer builds) at ${LOOPBACK}:${AEM_ENDPOINT_PORT}/azure4sap/metrics"

  if have_cmd curl; then
    set +e
    local response
    response=$(curl -sS --max-time 3 "http://${LOOPBACK}:${AEM_ENDPOINT_PORT}/azure4sap/metrics")
    local rc=$?
    set -e

    if [[ ${rc} -eq 0 && -n "${response}" ]]; then
      # minimal sanity: expect XML/JSON-like content with counters
      if echo "${response}" | head -n 1 | grep -Ei '<|{' >/dev/null 2>&1; then
        ok "Endpoint responded with metrics payload."
        RESULTS[endpoint_ok]="PASS"
      else
        warn "Endpoint responded but payload format looks unexpected."
        RESULTS[endpoint_ok]="PASS"
      fi
    else
      warn "Endpoint not reachable or empty. This may be OK if you are on an older (legacy) build."
      RESULTS[endpoint_ok]="SKIP"
    fi
  else
    warn "curl not available; skipping endpoint check."
    RESULTS[endpoint_ok]="SKIP"
  fi
}

# ---------- Check 4: Legacy PerfCounters ----------
check_legacy_perf() {
  hr
  log "Checking legacy PerfCounters location: ${AEM_LEGACY_DIR}"

  if [[ -d "${AEM_LEGACY_DIR}" ]]; then
    local perf_file="${AEM_LEGACY_DIR}/PerfCounters"
    local err_file="${AEM_LEGACY_DIR}/LatestErrorRecord"

    if [[ -s "${perf_file}" ]]; then
      ok "Legacy PerfCounters present and non-empty: ${perf_file}"
      RESULTS[legacy_perf_ok]="PASS"
    else
      warn "Legacy PerfCounters file missing or empty; might not be used on newer builds."
      RESULTS[legacy_perf_ok]="SKIP"
    fi

    if [[ -f "${err_file}" ]]; then
      local err_size
      err_size=$(stat -c%s "${err_file}" 2>/dev/null || echo 0)
      if [[ "${err_size}" -eq 0 ]]; then
        ok "Legacy error log is empty (no errors): ${err_file}"
        RESULTS[error_log_clean]="PASS"
      else
        warn "Legacy error log non-empty: ${err_file} (${err_size} bytes)"
        RESULTS[error_log_clean]="FAIL"
      fi
    else
      warn "No legacy error record file found."
      RESULTS[error_log_clean]="SKIP"
    fi
  else
    warn "Legacy directory ${AEM_LEGACY_DIR} not found; skipping legacy checks."
    RESULTS[legacy_perf_ok]="SKIP"
    RESULTS[error_log_clean]="SKIP"
  fi
}

# ---------- Check 5: saposcol presence ----------
check_saposcol() {
  hr
  log "Checking if saposcol is installed (optional for SAP)..."

  if have_cmd saposcol; then
    ok "saposcol found in PATH."
    RESULTS[saposcol_installed]="PASS"
  else
    warn "saposcol not found. This is optional unless you are running SAP workloads."
    RESULTS[saposcol_installed]="SKIP"
  fi
}

# ---------- Check 6: EnhancedAccess in Azure metadata ----------
check_enhanced_access() {
  hr
  log "Querying Azure Instance Metadata Service for EnhancedAccess flag..."

  if have_cmd curl; then
    set +e
    local meta
    meta=$(curl -sS -H "Metadata:true" --max-time 3 \
      "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01")
    local rc=$?
    set -e

    if [[ ${rc} -eq 0 && -n "${meta}" ]]; then
      # Try to parse out enhancedMonitoring or EnhancedAccess field
      # (Field name can vary by API version; might be 'azEnvironment.enhancedMonitoring' or similar)
      local enhanced_val
      enhanced_val=$(echo "${meta}" | grep -i "enhancedMonitoring\|EnhancedAccess" || true)

      if [[ -n "${enhanced_val}" ]]; then
        if echo "${enhanced_val}" | grep -qi "true"; then
          ok "EnhancedAccess/enhancedMonitoring detected in metadata."
          RESULTS[enhanced_access_true]="PASS"
        else
          warn "EnhancedAccess field found but not set to true."
          RESULTS[enhanced_access_true]="FAIL"
        fi
      else
        warn "No EnhancedAccess/enhancedMonitoring field in metadata response."
        RESULTS[enhanced_access_true]="SKIP"
      fi
    else
      warn "Could not query Azure metadata; may be offline or restricted."
      RESULTS[enhanced_access_true]="SKIP"
    fi
  else
    warn "curl not available; skipping IMDS check."
    RESULTS[enhanced_access_true]="SKIP"
  fi
}

# ---------- Final summary ----------
print_summary() {
  hr
  log "VALIDATION SUMMARY"
  hr
  local critical_fail=0

  for key in "${!RESULTS[@]}"; do
    local val="${RESULTS[$key]}"
    local display="${key//_/ }"
    case "${val}" in
      PASS)
        printf "${STATUS_COLOR_PASS}%-30s: PASS${STATUS_COLOR_RESET}\n" "${display}"
        ;;
      FAIL)
        printf "${STATUS_COLOR_FAIL}%-30s: FAIL${STATUS_COLOR_RESET}\n" "${display}"
        # Mark critical if files_present or process_running fails
        if [[ "${key}" == "files_present" || "${key}" == "process_running" ]]; then
          critical_fail=1
        fi
        ;;
      SKIP)
        printf "${STATUS_COLOR_SKIP}%-30s: SKIP${STATUS_COLOR_RESET}\n" "${display}"
        ;;
      *)
        printf "%-30s: UNKNOWN\n" "${display}"
        ;;
    esac
  done

  hr
  if [[ ${critical_fail} -eq 1 ]]; then
    err "One or more critical checks FAILED. Extension may not be working correctly."
    return 1
  else
    ok "All critical checks passed. Extension appears to be operational."
    return 0
  fi
}

# ---------- Main ----------
main() {
  log "==========================================================="
  log "Azure Enhanced Monitoring Extension Validation"
  log "==========================================================="
  log ""

  check_files_present
  check_process_running
  check_local_endpoint
  check_legacy_perf
  check_saposcol
  check_enhanced_access

  log ""
  print_summary
}

main
