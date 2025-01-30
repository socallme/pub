#!/bin/bash
set -euo pipefail

# ----- Configuration -----
API_URL="http://192.168.20.198:5000/cmk/check_mk/api/1.0"
API_IP=$(echo "$API_URL" | awk -F[/:] '{print $4}')
FOLDER_NAME="collected"
FOLDER_TITLE="Auto-collected Hosts"
USERNAME="register"
PASSWORD="pleaseSETUP"
HOST_NAME=$(hostname)
HOST_IP="xxx"
AGENT_DEB_URL="http://xxx:5000/cmk/check_mk/agents/check-mk-agent_2.3.0p25-1_all.deb"


# ----- Network Detection -----
detect_host_ip() {
    # Try to find the IP used to reach the API server
    local api_ip="$1"
    
    # First try using ip route
    local route_ip
    route_ip=$(ip route get "$api_ip" 2>/dev/null | awk -F'src ' '{print $2}' | awk '{print $1}')
    
    # Validate IP format
    if [[ "$route_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$route_ip"
        return 0
    fi
    
    # Fallback: Check active interfaces
    local interface_ip
    interface_ip=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | \
        grep -vE '^(127\.|169\.254|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | \
        head -n1)
    
    if [[ "$interface_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$interface_ip"
        return 0
    fi
    
    echo "ERROR: Could not determine valid IP address"
    return 1
}

# Detect host IP dynamically
HOST_IP=$(detect_host_ip "$API_IP") || { echo "$HOST_IP"; exit 1; }
echo "Detected host IP: $HOST_IP"


# ----- Helper Functions -----
api_request() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    
    curl --silent --show-error --fail \
        --request "$method" \
        --header "Authorization: Bearer $USERNAME $PASSWORD" \
        --header "Accept: application/json" \
        --header "Content-Type: application/json" \
        ${data:+--data "$data"} \
        "${API_URL}${endpoint}" | jq
}

# ----- Agent Management -----
install_checkmk_agent() {
    # Check if agent is already installed
    if command -v check_mk_agent >/dev/null 2>&1; then
        echo "Checkmk agent is already installed"
        return 0
    fi

    echo "Installing Checkmk agent..."
    
    # Create temp directory with cleanup trap
    local temp_dir
    temp_dir=$(mktemp -d) || { echo "Failed to create temp directory"; exit 1; }
    trap 'rm -rf "$temp_dir"' EXIT

    # Download agent
    if ! wget -q "$AGENT_DEB_URL" -O "$temp_dir/check-mk-agent.deb"; then
        echo "ERROR: Failed to download agent from $AGENT_DEB_URL"
        return 1
    fi

    # Install with error handling
    if ! dpkg -i "$temp_dir/check-mk-agent.deb"; then
        echo "Detected dependency issues, attempting to fix..."
        apt-get update && apt-get install -f -y
        if ! dpkg -i "$temp_dir/check-mk-agent.deb"; then
            echo "ERROR: Failed to install Checkmk agent"
            return 1
        fi
    fi

    # Verify installation
    if ! command -v check_mk_agent >/dev/null 2>&1; then
        echo "ERROR: Agent installation verification failed"
        return 1
    fi

    echo "Checkmk agent installed successfully"
}

# ----- Host Management -----
host_exists() {
    local status_code
    status_code=$(curl --silent -o /dev/null -w "%{http_code}" \
        --header "Authorization: Bearer $USERNAME $PASSWORD" \
        "${API_URL}/objects/host_config/$HOST_NAME")
        
    [ "$status_code" -eq 200 ]
}

manage_host() {
    if host_exists; then
        echo "Host $HOST_NAME already exists. Updating configuration..."
        api_request PUT "/objects/host_config/$HOST_NAME" \
            "{
                \"attributes\": {
                    \"ipaddress\": \"$HOST_IP\",
                    \"tag_piggyback\": \"auto-piggyback\",
                    \"tag_agent\": \"cmk-agent\",
                    \"site\": \"cmk\"
                }
            }"
    else
        echo "Registering new host: $HOST_NAME..."
        api_request POST "/domain-types/host_config/collections/all" \
            "{
                \"host_name\": \"$HOST_NAME\",
                \"folder\": \"/\",
                \"attributes\": {
                    \"ipaddress\": \"$HOST_IP\",
                    \"tag_piggyback\": \"auto-piggyback\",
                    \"tag_agent\": \"cmk-agent\",
                    \"site\": \"cmk\"
                }
            }"
    fi
}

# ----- Remaining Functions (activate_changes, run_service_discovery, main) -----
# ... [Keep these functions identical to your original improved version] ...

activate_changes() {
    echo "Fetching ETag for pending changes..."
    local headers
    headers=$(curl --silent -i \
        --header "Authorization: Bearer $USERNAME $PASSWORD" \
        --header "Accept: application/json" \
        "${API_URL}/domain-types/activation_run/collections/pending_changes")
        
    local etag
    etag=$(grep -i "ETag:" <<< "$headers" | awk '{print $2}' | tr -d '\r"')
    
    [ -z "$etag" ] && { echo "Error: No ETag found"; exit 1; }
    
    echo "Activating changes with ETag: $etag..."
    api_request POST "/domain-types/activation_run/actions/activate-changes/invoke" \
        "{
            \"force_foreign_changes\": false,
            \"redirect\": false,
            \"sites\": [\"cmk\"],
            \"_etag\": \"$etag\"
        }"
}

run_service_discovery() {
    echo "Starting service discovery for $HOST_NAME..."
    api_request POST "/domain-types/service_discovery_run/actions/start/invoke" \
        "{\"host_name\": \"$HOST_NAME\", \"mode\": \"refresh\"}"
    echo "Service discovery completed successfully"
}

# ----- Execution Flow -----
main() {
    install_checkmk_agent || exit 1
    manage_host
    activate_changes
    run_service_discovery
}

main
