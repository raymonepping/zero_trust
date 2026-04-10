#!/usr/bin/env bash
#
# generate_json_files.sh
# Copies the input users.json and generates fully randomized activity files.
#
# Outputs: users.json  activity.json  projects.json  tickets.json  training.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate_json_files.sh <users.json> [--output-dir <dir>]

Description:
  Copies the input users.json and generates fully randomized JSON files in
  the target directory, preserving the exact same schema as the originals:
    users.json     activity.json   projects.json
    tickets.json   training.json

Arguments:
  <users.json>          Path to a users JSON array file

Options:
  --output-dir <dir>    Write output files here (default: ./data)
  -h, --help            Show this help

Examples:
  ./scripts/generate_json_files.sh data/users.json
  ./scripts/generate_json_files.sh data/input/users_example.json --output-dir /tmp/demo
EOF
}

info()  { printf '==> %s\n' "$*"; }
error() { printf 'ERR %s\n' "$*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────
INPUT_FILE=""
OUTPUT_DIR="${REPO_ROOT}/data"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output-dir)
      OUTPUT_DIR="${2:?--output-dir requires a value}"
      shift 2
      ;;
    -*)
      error "Unknown option: $1"
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$INPUT_FILE" ]]; then
        INPUT_FILE="$1"
      else
        error "Unexpected argument: $1"
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$INPUT_FILE" ]]; then
  error "No input file specified."
  usage >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  error "Input file not found: $INPUT_FILE"
  exit 1
fi

command -v jq >/dev/null 2>&1 || { error "Required command not found: jq"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# ── Date helper ───────────────────────────────────────────────────────────────
if date -j >/dev/null 2>&1; then _DATE_MACOS=1; else _DATE_MACOS=0; fi

_to_epoch() {
  if [[ $_DATE_MACOS -eq 1 ]]; then date -j -f "%Y-%m-%d" "$1" "+%s"
  else date -d "$1" "+%s"; fi
}
_from_epoch() {
  if [[ $_DATE_MACOS -eq 1 ]]; then date -j -r "$1" "+%Y-%m-%d"
  else date -d "@$1" "+%Y-%m-%d"; fi
}

random_date() {
  local from="${1:-2024-01-01}" to="${2:-2026-03-31}"
  local s e range epoch
  s="$(_to_epoch "$from")"
  e="$(_to_epoch "$to")"
  range=$(( e - s ))
  epoch=$(( s + (RANDOM << 15 | RANDOM) % range ))
  _from_epoch "$epoch"
}

# ── Random helpers ────────────────────────────────────────────────────────────
rand_pick() { local arr=("$@"); echo "${arr[$(( RANDOM % ${#arr[@]} ))]}"; }

random_price() {
  local min=$1 max=$2
  local dollars=$(( min + (RANDOM * 32768 + RANDOM) % (max - min + 1) ))
  if (( dollars >= 500 )); then printf "%d.00" "$dollars"
  else
    case $(( RANDOM % 4 )) in
      0) printf "%d.00" "$dollars" ;; 1) printf "%d.99" "$dollars" ;;
      2) printf "%d.95" "$dollars" ;; 3) printf "%d.50" "$dollars" ;;
    esac
  fi
}

random_classification() {
  local r=$(( RANDOM % 100 ))
  if   (( r <  40 )); then echo "public"
  elif (( r <  70 )); then echo "internal"
  elif (( r <  85 )); then echo "confidential"
  else                     echo "restricted"
  fi
}

# ── Read user IDs ─────────────────────────────────────────────────────────────
mapfile -t USER_IDS < <(jq -r '.[].id' "$INPUT_FILE")
if [[ ${#USER_IDS[@]} -eq 0 ]]; then
  error "No users found in $INPUT_FILE — expected a JSON array of user objects"
  exit 1
fi
info "Generating data for ${#USER_IDS[@]} user(s) → ${OUTPUT_DIR}"

# ═════════════════════════════════════════════════════════════════════════════
# POOLS
# ═════════════════════════════════════════════════════════════════════════════

# ── Orders ────────────────────────────────────────────────────────────────────
ITEMS=(
  "Mechanical Keyboard – Keychron Q5 Pro|Tech|159|229"
  "Sony WH-1000XM5 Headphones|Tech|299|399"
  "Apple MacBook Pro 16-inch M3 Max|Tech|2999|3999"
  "iPad Pro 13-inch M4|Tech|1099|1499"
  "Dell XPS 15 Laptop|Tech|1399|1899"
  "LG UltraWide 34\" Monitor|Tech|499|799"
  "Logitech MX Master 3S Mouse|Tech|89|109"
  "Framework Laptop 13 – AMD Ryzen 7|Tech|1599|1899"
  "Cisco Webex Desk Pro|Tech|2499|3499"
  "Noise-Cancelling Headset – Jabra Evolve2 85|Tech|399|499"
  "Bose SoundLink Revolve+ Speaker|Audio|249|349"
  "Standing Desk – Flexispot E7|Office|499|699"
  "Ergonomic Office Chair – Herman Miller Aeron|Office|1299|1699"
  "Monitor Arm – Ergotron LX|Office|79|149"
  "Standing Desk Mat – Anti-Fatigue|Office|39|79"
  "Webcam – Logitech Brio 4K|Office|149|229"
  "Whiteboard – 48x36 Magnetic|Office|89|139"
  "HashiCorp Vault Deep Dive – Udemy Course|Education|14|29"
  "Cloud Security Handbook – O'Reilly|Education|49|79"
  "Python for Data Science – Coursera Annual|Education|299|499"
  "Terraform Associate Certification Exam|Education|60|90"
  "AWS Solutions Architect Exam Voucher|Education|150|200"
  "Kubernetes Application Developer Exam|Education|395|395"
  "AWS re:Invent Conference Ticket|Events|1500|2500"
  "KubeCon Conference Ticket|Events|999|1899"
  "HashiConf Global Ticket|Events|1200|2200"
  "VMware vSphere License – Enterprise|Software|4500|8000"
  "HashiCorp Vault Enterprise License|Software|20000|35000"
  "GitHub Enterprise – Annual|Software|1800|2400"
  "JetBrains All Products Pack – Annual|Software|249|329"
  "Figma Professional Annual Subscription|Software|144|216"
  "1Password Teams – Annual|Software|95|135"
  "Datadog Pro Plan – Monthly|Software|199|299"
  "Dell PowerEdge R750 Server|Infrastructure|7000|12000"
  "Synology NAS DS923+|Infrastructure|599|899"
  "Raspberry Pi 5 Cluster Kit|Infrastructure|249|399"
  "Security Audit Consulting – 2 days|Professional Services|3500|6000"
  "Zero Trust Architecture Consulting – 5 days|Professional Services|10000|18000"
  "Penetration Testing Contract – Q2|Professional Services|8000|15000"
  "Privileged Access Review Workshop|Professional Services|7000|12000"
  "Specialty Coffee Subscription – 3 months|Food & Drink|60|90"
  "Pasta Maker Machine – Marcato Atlas 150|Kitchen|79|119"
  "Nike Air Zoom Pegasus 41|Sports|119|149"
  "Yoga Mat – Lululemon 5mm|Sports|78|108"
  "Customer Journey Research Panel – Benelux|Research|3000|5500"
)

# ── Preferences ───────────────────────────────────────────────────────────────
MUSIC_PREFS=("Electronic, Techno, Deep House" "Jazz, Classical, Indie Rock" "Pop, R&B, Soul"
  "Hip Hop, Funk, Blues" "Techno, Ambient, Krautrock" "Drum & Bass, Ambient, Dutch Hip Hop"
  "Metal, Punk, Alternative Rock" "Folk, Country, Americana" "Classical, Opera, Baroque"
  "Reggae, Afrobeat, World Music" "Synthwave, Darkwave, Industrial" "Lo-Fi, Jazz Hop, Chillout")

SPORTS_PREFS=("Cycling, Swimming" "Running, Hiking, Football" "Yoga, Pilates, Tennis"
  "Basketball, Surfing, Rock Climbing" "Football, Cycling, Bouldering" "Padel, Cycling, Indoor Climbing"
  "CrossFit, Rowing, Trail Running" "Golf, Swimming, Skiing" "Martial Arts, Boxing, Gymnastics"
  "Triathlon, Open Water Swimming, Road Cycling" "Volleyball, Badminton, Skateboarding")

CUISINE_PREFS=("Japanese, Italian" "Italian, Mediterranean, Street Food" "Thai, Lebanese, Vegan"
  "Mexican, Korean BBQ, Cajun" "German, Japanese, Lebanese" "Indonesian, Italian, Korean"
  "French, Spanish, Greek" "Indian, Ethiopian, Vietnamese" "Peruvian, Chinese, Turkish"
  "Brazilian, Portuguese, Moroccan")

TECH_PREFS=("DevOps, Security, Cloud Infrastructure, HashiCorp tooling"
  "Virtualisation, Storage, Cloud Infrastructure" "Security Engineering, Penetration Testing, Zero Trust"
  "Data Science, MLOps, Cloud Architecture" "Platform Engineering, IaC, HashiCorp Stack"
  "Identity, UX Engineering, Secure Developer Platforms" "SRE, Observability, Chaos Engineering"
  "Kubernetes, Service Mesh, GitOps" "AI/ML Infrastructure, LLMOps, Vector Databases"
  "FinOps, Cost Optimisation, Cloud Governance" "AppSec, SAST, Supply Chain Security")

TRAVEL_PREFS=("Japan, Iceland, Portugal" "Italy, Morocco, New Zealand" "Thailand, Canada, South Africa"
  "Japan, Brazil, Australia" "Japan, Argentina, Norway" "Portugal, Singapore, Denmark"
  "Peru, Kenya, Georgia" "Vietnam, Mexico, Croatia" "Scotland, Ethiopia, Colombia"
  "Chile, Bhutan, Finland" "UAE, Taiwan, Slovenia")

SALARY_BANDS=("L3 – Engineer" "L4 – Senior Engineer" "L5 – Staff Engineer"
  "L5 – Lead Engineer" "L6 – Senior Principal" "L7 – Distinguished Engineer" "L8 – Fellow")

CLEARANCES=("Level 1 – Public Trust" "Level 2 – Basic" "Level 3 – Confidential"
  "Level 4 – Secret" "Level 5 – Top Secret")

PREF_PROJECTS=("Internal IAM Modernisation Pilot" "Zero Trust Network Segmentation Phase 2"
  "Cloud Migration – Wave 3" "SOC 2 Type II Audit Preparation" "Identity Governance Rollout"
  "Privileged Access Management Uplift" "Data Classification Programme"
  "Developer Platform Consolidation" "Security Posture Review – Q3"
  "Hybrid Cloud Connectivity Initiative")

# ── Projects ──────────────────────────────────────────────────────────────────
PROJECT_NAMES=("Vault Migration Wave 2" "Privileged Identity Breakglass Redesign"
  "Support Access Workflow Hardening" "Secrets Rotation Runbook Automation"
  "Role-Aware Dashboard Refresh" "Restricted UX Pattern Review"
  "AI Knowledge Assistant Pilot" "Confidential Model Evaluation Track"
  "Platform Bootstrap Standardization" "Enterprise License Governance"
  "Support Console Modernization" "Identity Operations Metrics Rollout"
  "Zero Trust Posture Assessment" "CIAM Integration Sprint"
  "Secrets Sprawl Remediation" "PKI Automation Initiative"
  "Cloud Boundary Enforcement Project" "AppSec Pipeline Hardening"
  "Federated Identity Rollout" "Data Residency Compliance Programme"
  "Insider Threat Detection Tooling" "Threat Modelling Workshop Series"
  "Kubernetes RBAC Consolidation" "Service Account Credential Rotation"
  "Audit Trail Centralisation Project" "Hybrid Cloud Networking Uplift")

PROJECT_ROLES=("Principal Engineer" "Technical Lead" "Staff Engineer" "Implementation Lead"
  "Frontend Engineer" "Design Reviewer" "Data Engineer" "Analytics Lead"
  "Platform Engineer" "Systems Owner" "Support Engineer" "Operations Lead"
  "Security Architect" "Product Owner" "DevOps Engineer" "SRE Lead"
  "Compliance Officer" "Delivery Manager")

PROJECT_STATUSES=("active" "active" "active" "planning" "planning" "completed" "on_hold")

# ── Tickets ───────────────────────────────────────────────────────────────────
TICKET_TITLES_VAULT=("Vault token renewal intermittently fails"
  "AppRole secret_id expires before expected TTL" "Vault agent not restarting after container restart"
  "KV v2 metadata returns 403 for viewer role" "Audit log grows unbounded — rotation not triggering"
  "Vault seal status check fails in healthcheck" "Dynamic credentials not revoked after lease expiry"
  "Namespace policy inheritance not propagating" "Vault agent sink file missing after stack restart")

TICKET_TITLES_IAM=("Production admin access review for finance namespace"
  "Stale role bindings after user offboarding" "OIDC login flow returns stale role claims"
  "Service account rotation blocked by policy conflict" "Group membership not reflected in token claims"
  "JWT audience validation fails for external IdP" "LDAP group sync not updating Vault roles"
  "Bootstrap admin account still active in production")

TICKET_TITLES_BACKEND=("Support team cannot read confidential preferences"
  "Backend returns 500 on expired Vault credential" "/api/ask endpoint timeouts under load"
  "CORS header missing on /api/credentials" "Connector hot-reload fails after nodemon restart"
  "Rate limiting not applied to anonymous endpoint")

TICKET_TITLES_KEYCLOAK=("OIDC login flow returns stale role claims"
  "CIBA polling returns 400 after 30 seconds" "Realm JWKS endpoint returns 503 intermittently"
  "User federation not syncing new LDAP entries" "Client secret rotation not reflected in token endpoint"
  "Backchannel authentication endpoint unreachable from backend")

TICKET_TITLES_FRONTEND=("Viewer dashboard card loads slowly on mobile"
  "Restricted content visible to viewer role briefly on load" "AI answer stream cuts off mid-response"
  "Health indicator shows stale status after reconnect" "Credential badge flickers on rapid role switch"
  "Dark mode toggle not persisted across sessions")

TICKET_TITLES_POSTGRES=("Platform role rotation skipped after database restart"
  "RLS policy not applied to support-write role" "Dynamic credential hits max connections limit"
  "Backup job interferes with credential lease renewal" "EXPLAIN output shows sequential scan on orders table"
  "Support-read role can see restricted rows")

TICKET_TITLES_OTHER=("Enterprise license audit requested by procurement"
  "LLM endpoint timed out during data summarization" "Confidential project notes exposed in generated answer"
  "Support escalation cannot rotate lease on demand" "Restricted customer panel access review"
  "Ollama model not loaded after container restart" "Embedding generation fails for long inputs")

TICKET_SYSTEMS=("vault" "iam" "backend-api" "keycloak" "frontend" "postgres"
  "ollama" "ask-api" "support-console" "licensing" "ldap")

TICKET_PRIORITIES=("low" "medium" "medium" "high" "high" "critical")
TICKET_STATUSES=("open" "open" "in_progress" "investigating" "pending" "resolved" "resolved")

# ── Training ──────────────────────────────────────────────────────────────────
COURSES=(
  "Zero Trust Architecture Fundamentals|HashiCorp Academy|public"
  "Vault Policy Design Workshop|Internal Security Enablement|internal"
  "Privileged Access Incident Response|Red Team Lab|restricted"
  "Identity Federation with OIDC|Cloud Native Academy|public"
  "Kubernetes Secrets Hardening|Internal Platform Guild|internal"
  "Operational Secrets Escalation Drills|Security Operations|restricted"
  "Secure Frontend Authentication Patterns|Frontend Guild|public"
  "Phishing Resistance Simulation|Awareness Team|internal"
  "MLOps Data Handling and Privacy|AI Enablement Office|public"
  "Confidential Dataset Access Controls|Data Governance Board|confidential"
  "Terraform State Security|HashiCorp Academy|public"
  "Platform Access Boundary Reviews|Internal Platform Guild|internal"
  "Support Access Triage with Vault|Support Engineering Academy|public"
  "Identity Lifecycle Operations|Internal IAM Team|internal"
  "Privileged Support Escalation Handling|Security Operations|restricted"
  "AppSec Fundamentals – OWASP Top 10|Security Guild|public"
  "Dynamic Secrets and Lease Management|HashiCorp Academy|public"
  "CIAM and Federated Identity Design|Cloud Native Academy|internal"
  "Threat Modelling for Distributed Systems|Red Team Lab|confidential"
  "SOC 2 Evidence Collection Workshop|Compliance Office|internal"
  "Data Residency and Sovereignty Controls|Legal & Privacy|confidential"
  "Kubernetes RBAC Deep Dive|Internal Platform Guild|internal"
  "AWS Security Specialty Prep|Cloud Enablement|public"
  "Zero Trust Network Access Patterns|Security Guild|internal"
  "Incident Command System for Engineers|Security Operations|internal"
  "Supply Chain Security and SBOM|AppSec Team|confidential"
  "PKI and Certificate Lifecycle|Internal Security Enablement|internal"
  "Service Mesh Security with Istio|Platform Engineering|internal"
  "Secure SDLC for Backend Engineers|AppSec Team|internal"
  "GDPR Technical Controls Workshop|Legal & Privacy|confidential"
)

# ═════════════════════════════════════════════════════════════════════════════
# GENERATORS
# ═════════════════════════════════════════════════════════════════════════════

# ── activity.json ─────────────────────────────────────────────────────────────
info "Generating activity.json..."
orders_parts=()
prefs_parts=()

for uid in "${USER_IDS[@]}"; do
  num_orders=$(( RANDOM % 5 + 3 ))
  for (( i=0; i<num_orders; i++ )); do
    item_entry="$(rand_pick "${ITEMS[@]}")"
    IFS='|' read -r item_name category price_min price_max <<< "$item_entry"
    price="$(random_price "$price_min" "$price_max")"
    price_int="${price%%.*}"
    qty=1
    (( price_int < 100 )) && qty=$(( RANDOM % 3 + 1 ))
    orders_parts+=("$(jq -n \
      --argjson uid "$uid" --arg item "$item_name" --arg cat "$category" \
      --argjson qty "$qty" --argjson price "$price" \
      --arg date "$(random_date)" --arg cls "$(random_classification)" \
      '{user_id:$uid,item:$item,category:$cat,quantity:$qty,price:$price,ordered_at:$date,classification:$cls}')")
  done

  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${MUSIC_PREFS[@]}")" \
    '{user_id:$uid,category:"Music",value:$val,classification:"public"}')")
  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${SPORTS_PREFS[@]}")" \
    '{user_id:$uid,category:"Sports",value:$val,classification:"public"}')")
  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${CUISINE_PREFS[@]}")" \
    '{user_id:$uid,category:"Cuisine",value:$val,classification:"public"}')")
  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${TECH_PREFS[@]}")" \
    '{user_id:$uid,category:"Tech Interests",value:$val,classification:"internal"}')")
  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${TRAVEL_PREFS[@]}")" \
    '{user_id:$uid,category:"Travel",value:$val,classification:"public"}')")
  prefs_parts+=("$(jq -n --argjson uid "$uid" --arg val "$(rand_pick "${SALARY_BANDS[@]}")" \
    '{user_id:$uid,category:"Salary Band",value:$val,classification:"restricted"}')")
  (( RANDOM % 10 < 6 )) && prefs_parts+=("$(jq -n --argjson uid "$uid" \
    --arg val "$(rand_pick "${CLEARANCES[@]}")" \
    '{user_id:$uid,category:"Security Clearance",value:$val,classification:"restricted"}')")
  (( RANDOM % 10 < 4 )) && prefs_parts+=("$(jq -n --argjson uid "$uid" \
    --arg val "$(rand_pick "${PREF_PROJECTS[@]}")" \
    '{user_id:$uid,category:"Project",value:$val,classification:"confidential"}')")
done

jq -n \
  --argjson orders      "$(printf '%s\n' "${orders_parts[@]}" | jq -s '.')" \
  --argjson preferences "$(printf '%s\n' "${prefs_parts[@]}"  | jq -s '.')" \
  '{orders:$orders,preferences:$preferences}' > "${OUTPUT_DIR}/activity.json"
info "  orders: $(jq '.orders|length' "${OUTPUT_DIR}/activity.json")  preferences: $(jq '.preferences|length' "${OUTPUT_DIR}/activity.json")"

# ── projects.json ─────────────────────────────────────────────────────────────
info "Generating projects.json..."
project_parts=()

for uid in "${USER_IDS[@]}"; do
  num=$(( RANDOM % 3 + 1 ))   # 1–3 projects per user
  for (( i=0; i<num; i++ )); do
    budget=$(( (RANDOM % 230 + 20) * 1000 ))   # 20k–250k
    project_parts+=("$(jq -n \
      --argjson uid    "$uid" \
      --arg     name   "$(rand_pick "${PROJECT_NAMES[@]}")" \
      --arg     role   "$(rand_pick "${PROJECT_ROLES[@]}")" \
      --argjson budget "$budget" \
      --arg     date   "$(random_date "2024-01-01" "2025-12-31")" \
      --arg     status "$(rand_pick "${PROJECT_STATUSES[@]}")" \
      --arg     cls    "$(random_classification)" \
      '{user_id:$uid,project_name:$name,role:$role,budget:$budget,start_date:$date,status:$status,classification:$cls}')")
  done
done

printf '%s\n' "${project_parts[@]}" | jq -s '.' > "${OUTPUT_DIR}/projects.json"
info "  projects: $(jq 'length' "${OUTPUT_DIR}/projects.json")"

# ── tickets.json ──────────────────────────────────────────────────────────────
info "Generating tickets.json..."
ticket_parts=()

ALL_TICKET_TITLES=(
  "${TICKET_TITLES_VAULT[@]}"
  "${TICKET_TITLES_IAM[@]}"
  "${TICKET_TITLES_BACKEND[@]}"
  "${TICKET_TITLES_KEYCLOAK[@]}"
  "${TICKET_TITLES_FRONTEND[@]}"
  "${TICKET_TITLES_POSTGRES[@]}"
  "${TICKET_TITLES_OTHER[@]}"
)

for uid in "${USER_IDS[@]}"; do
  num=$(( RANDOM % 3 + 1 ))   # 1–3 tickets per user
  for (( i=0; i<num; i++ )); do
    ticket_parts+=("$(jq -n \
      --argjson uid    "$uid" \
      --arg     title  "$(rand_pick "${ALL_TICKET_TITLES[@]}")" \
      --arg     system "$(rand_pick "${TICKET_SYSTEMS[@]}")" \
      --arg     prio   "$(rand_pick "${TICKET_PRIORITIES[@]}")" \
      --arg     status "$(rand_pick "${TICKET_STATUSES[@]}")" \
      --arg     date   "$(random_date "2024-03-01" "2026-04-10")" \
      --arg     cls    "$(random_classification)" \
      '{user_id:$uid,title:$title,system:$system,priority:$prio,status:$status,opened_at:$date,classification:$cls}')")
  done
done

printf '%s\n' "${ticket_parts[@]}" | jq -s '.' > "${OUTPUT_DIR}/tickets.json"
info "  tickets: $(jq 'length' "${OUTPUT_DIR}/tickets.json")"

# ── training.json ─────────────────────────────────────────────────────────────
info "Generating training.json..."
training_parts=()

for uid in "${USER_IDS[@]}"; do
  num=$(( RANDOM % 3 + 2 ))   # 2–4 courses per user
  for (( i=0; i<num; i++ )); do
    course_entry="$(rand_pick "${COURSES[@]}")"
    IFS='|' read -r course_name provider cls <<< "$course_entry"
    score=$(( RANDOM % 21 + 70 ))   # 70–90
    certified="false"
    (( score >= 80 && RANDOM % 2 == 0 )) && certified="true"
    training_parts+=("$(jq -n \
      --argjson uid  "$uid" \
      --arg  course  "$course_name" \
      --arg  prov    "$provider" \
      --arg  date    "$(random_date "2024-01-01" "2026-03-31")" \
      --argjson score  "$score" \
      --argjson cert   "$certified" \
      --arg  cls     "$cls" \
      '{user_id:$uid,course:$course,provider:$prov,completed_at:$date,score:$score,certified:$cert,classification:$cls}')")
  done
done

printf '%s\n' "${training_parts[@]}" | jq -s '.' > "${OUTPUT_DIR}/training.json"
info "  training: $(jq 'length' "${OUTPUT_DIR}/training.json")"

# ── users.json (copy) ─────────────────────────────────────────────────────────
cp "$INPUT_FILE" "${OUTPUT_DIR}/users.json"
info "Copied  users.json ($(jq 'length' "${OUTPUT_DIR}/users.json") users)"
