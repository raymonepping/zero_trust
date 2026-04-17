#!/bin/bash

# Zero Trust Workshop - Service Stop Script
# This script stops services in the correct order (reverse of startup)

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

# Function to stop a service
stop_service() {
    local service_name=$1
    
    if is_service_running "$service_name"; then
        print_info "Stopping $service_name..."
        podman compose stop "$service_name"
        print_success "$service_name stopped"
    else
        print_info "$service_name is not running"
    fi
}

# Function to stop multiple services
stop_services() {
    local services=("$@")
    
    for service in "${services[@]}"; do
        stop_service "$service"
    done
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Stop Zero Trust Workshop services in the correct order.

OPTIONS:
    --all               Stop all services
    --base              Stop base services (db, ollama, backend, frontend)
    --security          Stop security services (vault, vault-agent)
    --identity          Stop identity services (openldap, keycloak)
    --access            Stop Boundary access services (db, controller, workers)
    --targets           Stop Boundary target services (nginx, ssh)
    --storage           Stop MinIO storage service
    --tools             Stop admin tools (ldap-admin)
    --status            Show status of all services
    --help              Show this help message

EXAMPLES:
    $0 --all                        # Stop everything
    $0 --targets --access           # Stop Boundary services
    $0 --base                       # Stop base services
    $0 --status                     # Check service status

NOTE: Services are stopped in reverse dependency order to avoid errors.

EOF
}

# Function to stop admin tools
stop_tools() {
    print_info "=== Stopping Admin Tools ==="
    print_info "Services: ldap-admin"
    
    stop_service "ldap-admin"
}

# Function to stop storage services
stop_storage_services() {
    print_info "=== Stopping Storage Services ==="
    print_info "Services: minio"
    
    stop_service "minio"
}

# Function to stop Boundary target services
stop_target_services() {
    print_info "=== Stopping Boundary Target Services ==="
    print_info "Services: boundary-target (nginx), boundary-ssh (ubuntu)"
    
    stop_services "boundary-ssh" "boundary-target"
}

# Function to stop Boundary access services
stop_access_services() {
    print_info "=== Stopping Boundary Access Services ==="
    print_info "Services: boundary-egress-worker, boundary-ingress-worker, boundary-controller, boundary-db"
    
    # Stop in reverse order: workers -> controller -> db
    stop_services "boundary-egress-worker" "boundary-ingress-worker" "boundary-controller" "boundary-db"
}

# Function to stop base services
stop_base_services() {
    print_info "=== Stopping Base Services ==="
    print_info "Services: frontend, backend, ollama, db"
    
    # Stop in reverse order: frontend -> backend -> ollama -> db
    stop_services "frontend" "backend" "ollama" "db"
}

# Function to stop identity services
stop_identity_services() {
    print_info "=== Stopping Identity Services ==="
    print_info "Services: keycloak, openldap"
    
    stop_services "keycloak" "openldap"
}

# Function to stop security services
stop_security_services() {
    print_info "=== Stopping Security Services (Vault) ==="
    print_info "Services: vault-agent, vault"
    
    # Stop agent before vault
    stop_services "vault-agent" "vault"
}

# Function to stop all services
stop_all_services() {
    print_info "=== Stopping All Services ==="
    print_info "Stopping in reverse dependency order..."
    
    # Stop in reverse order of startup
    stop_tools
    stop_storage_services
    stop_target_services
    stop_access_services
    stop_base_services
    stop_identity_services
    stop_security_services
    
    print_success "All services stopped!"
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

# Main script logic
main() {
    if [ $# -eq 0 ]; then
        show_usage
        exit 0
    fi
    
    case "$1" in
        --all)
            stop_all_services
            ;;
        --base)
            stop_base_services
            ;;
        --security)
            stop_security_services
            ;;
        --identity)
            stop_identity_services
            ;;
        --access)
            stop_access_services
            ;;
        --targets)
            stop_target_services
            ;;
        --storage)
            stop_storage_services
            ;;
        --tools)
            stop_tools
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