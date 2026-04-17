#!/bin/bash

# Zero Trust Workshop - Service Startup Script
# This script starts services in the correct order, respecting dependencies across profiles

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a service is running
is_service_running() {
    local service_name=$1
    podman compose ps --format json 2>/dev/null | jq -s -e ".[] | select(.Service == \"$service_name\" and .State == \"running\")" > /dev/null 2>&1
}

# Function to check if a service is healthy
is_service_healthy() {
    local service_name=$1
    podman compose ps --format json 2>/dev/null | jq -s -e ".[] | select(.Service == \"$service_name\" and .Health == \"healthy\")" > /dev/null 2>&1
}

# Function to wait for a service to be healthy
wait_for_service() {
    local service_name=$1
    local max_attempts=${2:-30}
    local attempt=0
    
    print_info "Waiting for $service_name to be healthy..."
    
    while [ $attempt -lt $max_attempts ]; do
        if is_service_healthy "$service_name"; then
            print_success "$service_name is healthy"
            return 0
        fi
        
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    echo ""
    print_error "$service_name failed to become healthy after $((max_attempts * 2)) seconds"
    return 1
}

# Function to start a service without profile validation issues
start_service() {
    local service_name=$1
    
    print_info "Starting $service_name..."
    
    # Use podman directly to avoid profile validation
    if podman compose up -d "$service_name" 2>&1 | grep -q "invalid compose project"; then
        print_warning "Profile validation issue detected, using alternative method..."
        # Start all services in the required profiles together
        return 2
    fi
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        print_success "$service_name started"
        return 0
    else
        print_error "Failed to start $service_name"
        return 1
    fi
}

# Function to start multiple services together (avoids profile validation)
start_services_together() {
    local services=("$@")
    local service_list="${services[*]}"
    
    print_info "Starting services together: $service_list"
    
    podman compose up -d ${services[@]}
    
    if [ $? -eq 0 ]; then
        print_success "Services started: $service_list"
        return 0
    else
        print_error "Failed to start services: $service_list"
        return 1
    fi
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Start Zero Trust Workshop services in the correct order.

OPTIONS:
    --all               Start all services (all profiles)
    --base              Start base services (db, ollama, backend, frontend)
    --security          Start security services (vault, vault-agent)
    --identity          Start identity services (openldap, keycloak)
    --access            Start Boundary access services (db, controller, workers)
    --targets           Start Boundary target services (nginx, ssh)
    --storage           Start MinIO storage service
    --tools             Start admin tools (ldap-admin)
    --minimal           Start minimal stack (db, vault, backend, frontend)
    --stop              Stop all services
    --restart           Restart all services
    --status            Show status of all services
    --help              Show this help message

EXAMPLES:
    $0 --minimal                    # Start minimal working stack
    $0 --base --security            # Start base + security services
    $0 --all                        # Start everything
    $0 --access --targets           # Start Boundary with targets
    $0 --status                     # Check service status

NOTE: Services are started respecting dependencies across profiles.

EOF
}

# Function to start base services
start_base_services() {
    print_info "=== Starting Base Services ==="
    
    # Start db first (it has no dependencies)
    if ! is_service_running "db"; then
        start_services_together "db" || return 1
        wait_for_service "db" 30 || return 1
    else
        print_info "db is already running"
    fi
}

# Function to start security services (vault)
start_security_services() {
    print_info "=== Starting Security Services (Vault) ==="
    print_info "Services: vault, vault-agent"
    
    # Start Vault
    if ! is_service_running "vault"; then
        start_services_together "vault" || return 1
        wait_for_service "vault" 30 || return 1
        
        print_warning "Remember to unseal Vault: ./scripts/unseal_vault.sh"
        print_warning "Remember to login to Vault: ./scripts/vault_login.sh"
    else
        print_info "vault is already running"
    fi
    
    # Start Vault Agent (depends on vault)
    if ! is_service_running "vault-agent"; then
        start_services_together "vault-agent" || return 1
        wait_for_service "vault-agent" 30 || return 1
    else
        print_info "vault-agent is already running"
    fi
}

# Function to start identity services
start_identity_services() {
    print_info "=== Starting Identity Services ==="
    print_info "Services: openldap, keycloak"
    
    # Ensure Vault is running first (openldap depends on it)
    if ! is_service_running "vault"; then
        print_warning "Vault is not running. Starting security services first..."
        start_security_services || return 1
    fi
    
    # Start OpenLDAP
    if ! is_service_running "openldap"; then
        start_services_together "openldap" || return 1
        wait_for_service "openldap" 30 || return 1
        
        print_info "Remember to bootstrap LDAP: ./scripts/setup_ldap.sh"
    else
        print_info "openldap is already running"
    fi
    
    # Start Keycloak
    if ! is_service_running "keycloak"; then
        start_services_together "keycloak" || return 1
        wait_for_service "keycloak" 60 || return 1
        
        print_info "Remember to setup Keycloak: ./scripts/setup_keycloak.sh"
    else
        print_info "keycloak is already running"
    fi
}

# Function to start Boundary access services
start_access_services() {
    print_info "=== Starting Boundary Access Services ==="
    print_info "Services: boundary-db, boundary-controller, boundary-ingress-worker, boundary-egress-worker"
    
    # Check .env file for required variables
    if [ ! -f .env ]; then
        print_error ".env file not found. Please create it from .env.example"
        return 1
    fi
    
    # Start Boundary database
    if ! is_service_running "boundary-db"; then
        start_services_together "boundary-db" || return 1
        wait_for_service "boundary-db" 30 || return 1
    else
        print_info "boundary-db is already running"
    fi
    
    # Start Boundary controller
    if ! is_service_running "boundary-controller"; then
        start_services_together "boundary-controller" || return 1
        sleep 10  # Give controller time to initialize
    else
        print_info "boundary-controller is already running"
    fi
    
    # Start Boundary workers
    if ! is_service_running "boundary-ingress-worker"; then
        start_services_together "boundary-ingress-worker" || return 1
        sleep 5
    else
        print_info "boundary-ingress-worker is already running"
    fi
    
    if ! is_service_running "boundary-egress-worker"; then
        start_services_together "boundary-egress-worker" || return 1
        sleep 5
    else
        print_info "boundary-egress-worker is already running"
    fi
    
    print_success "Boundary access services ready at http://localhost:9200"
}

# Function to start Boundary target services
start_target_services() {
    print_info "=== Starting Boundary Target Services ==="
    print_info "Services: boundary-target (nginx), boundary-ssh (ubuntu)"
    
    # Start nginx target
    if ! is_service_running "boundary-target"; then
        start_services_together "boundary-target" || return 1
        sleep 3
    else
        print_info "boundary-target is already running"
    fi
    
    # Start SSH target
    if ! is_service_running "boundary-ssh"; then
        start_services_together "boundary-ssh" || return 1
        sleep 3
        print_info "SSH target available at localhost:2222 (boundary/password)"
    else
        print_info "boundary-ssh is already running"
    fi
    
    print_success "Boundary targets ready"
}

# Function to start storage services
start_storage_services() {
    print_info "=== Starting Storage Services ==="
    print_info "Services: minio"
    
    if ! is_service_running "minio"; then
        start_services_together "minio" || return 1
        sleep 5
        
        print_success "MinIO is ready at http://localhost:9001 (admin/minioadmin)"
    else
        print_info "minio is already running"
    fi
}

# Function to start admin tools
start_tools() {
    print_info "=== Starting Admin Tools ==="
    print_info "Services: ldap-admin"
    
    # LDAP Admin depends on openldap and vault
    if ! is_service_running "openldap"; then
        print_warning "OpenLDAP is not running. Starting identity services first..."
        start_identity_services || return 1
    fi
    
    if ! is_service_running "ldap-admin"; then
        start_services_together "ldap-admin" || return 1
        sleep 5
        
        print_success "LDAP Admin is ready at http://localhost:8081"
    else
        print_info "ldap-admin is already running"
    fi
}

# Function to stop all services
stop_all_services() {
    print_info "=== Stopping All Services ==="
    podman compose down
    print_success "All services stopped"
}

# Function to restart all services
restart_all_services() {
    print_info "=== Restarting All Services ==="
    stop_all_services
    sleep 3
    start_all_services
}

# Function to show status
show_status() {
    print_info "=== Zero Trust Workshop - Service Status ==="
    echo ""
    
    # Get all services (running and stopped) - convert to proper JSON array
    local services=$(podman compose ps -a --format json 2>/dev/null | jq -s '.' 2>/dev/null)
    
    if [ -z "$services" ] || [ "$services" = "[]" ] || [ "$services" = "null" ]; then
        print_warning "No services found"
        return 0
    fi
    
    # Function to check and display service group
    show_service_group() {
        local group_name=$1
        shift
        local service_names=("$@")
        local found=false
        
        for service in "${service_names[@]}"; do
            local service_data=$(echo "$services" | jq -r ".[] | select(.Service == \"$service\")" 2>/dev/null)
            
            if [ -n "$service_data" ] && [ "$service_data" != "null" ]; then
                if [ "$found" = false ]; then
                    echo -e "\n${BLUE}${group_name}:${NC}"
                    printf "  %-25s %-15s %-20s %s\n" "SERVICE" "STATUS" "UPTIME" "PORTS"
                    printf "  %-25s %-15s %-20s %s\n" "-------" "------" "------" "-----"
                    found=true
                fi
                
                local status=$(echo "$service_data" | jq -r '.State' 2>/dev/null)
                local uptime=$(echo "$service_data" | jq -r '.Status' 2>/dev/null)
                local ports=$(echo "$service_data" | jq -r '.Publishers // [] | map("\(.PublishedPort)->\(.TargetPort)") | join(", ")' 2>/dev/null)
                
                # Color code status
                local status_colored
                if [ "$status" = "running" ]; then
                    status_colored="${GREEN}running${NC}"
                elif [ "$status" = "exited" ]; then
                    status_colored="${YELLOW}stopped${NC}"
                else
                    status_colored="${RED}${status}${NC}"
                fi
                
                # Truncate uptime if too long
                if [ ${#uptime} -gt 20 ]; then
                    uptime="${uptime:0:17}..."
                fi
                
                # Truncate ports if too long
                if [ ${#ports} -gt 40 ]; then
                    ports="${ports:0:37}..."
                fi
                
                printf "  %-25s %-24s %-20s %s\n" "$service" "$(echo -e $status_colored)" "$uptime" "$ports"
            fi
        done
    }
    
    # Display services by group
    show_service_group "Base Services" "db" "ollama" "backend" "frontend"
    show_service_group "Security (Vault)" "vault" "vault-agent"
    show_service_group "Identity" "openldap" "keycloak"
    show_service_group "Boundary Access" "boundary-db" "boundary-controller" "boundary-ingress-worker" "boundary-egress-worker"
    show_service_group "Boundary Targets" "boundary-target" "boundary-ssh"
    show_service_group "Storage" "minio"
    show_service_group "Tools" "ldap-admin"
    
    echo ""
    local running=$(echo "$services" | jq '[.[] | select(.State == "running")] | length' 2>/dev/null)
    local stopped=$(echo "$services" | jq '[.[] | select(.State != "running")] | length' 2>/dev/null)
    print_success "Services: $running running, $stopped stopped"
}

# Function to start minimal stack
start_minimal_stack() {
    print_info "=== Starting Minimal Stack ==="
    print_info "This will start: db, vault, vault-agent, backend, frontend"
    
    start_base_services || return 1
    start_security_services || return 1
    
    # Start backend and frontend (without ollama for minimal)
    if ! is_service_running "backend"; then
        start_services_together "backend" || return 1
        wait_for_service "backend" 30 || return 1
    fi
    
    if ! is_service_running "frontend"; then
        start_services_together "frontend" || return 1
        wait_for_service "frontend" 30 || return 1
    fi
    
    print_success "Minimal stack is ready!"
    print_info "Frontend: http://localhost:8088"
    print_info "Backend: http://localhost:3000"
    print_info "Vault: http://localhost:8200"
}

# Function to start all services
start_all_services() {
    print_info "=== Starting All Services ==="
    
    start_base_services || return 1
    start_security_services || return 1
    start_identity_services || return 1
    start_access_services || return 1
    start_target_services || return 1
    start_storage_services || return 1
    start_tools || return 1
    
    print_success "All services started!"
    print_info ""
    print_info "Service URLs:"
    print_info "  Frontend:    http://localhost:8088"
    print_info "  Backend:     http://localhost:3000"
    print_info "  Vault:       http://localhost:8200"
    print_info "  Keycloak:    http://localhost:8082"
    print_info "  LDAP Admin:  http://localhost:8081"
    print_info "  Boundary:    http://localhost:9200"
    print_info "  MinIO:       http://localhost:9001"
    print_info "  SSH Target:  ssh -p 2222 boundary@localhost"
}

# Main script logic
main() {
    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    case "$1" in
        --all)
            start_all_services
            ;;
        --base)
            start_base_services
            ;;
        --security)
            start_security_services
            ;;
        --identity)
            start_identity_services
            ;;
        --access)
            start_access_services
            ;;
        --targets)
            start_target_services
            ;;
        --storage)
            start_storage_services
            ;;
        --tools)
            start_tools
            ;;
        --minimal)
            start_minimal_stack
            ;;
        --stop)
            stop_all_services
            ;;
        --restart)
            restart_all_services
            ;;
        --status)
            show_status
            ;;
        --help)
            show_usage
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

# Made with Bob
