#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

echo -e "${GREEN}Starting installation of Pi-hole Docker DNS sync...${NC}"

# Function to check and install packages
install_package() {
    if ! dpkg -l | grep -q "^ii  $1 "; then
        echo -e "${YELLOW}Installing $1...${NC}"
        apt-get install -y $1
    fi
}

# Update package list
echo -e "${YELLOW}Updating package list...${NC}"
apt-get update

# Install required system packages
install_package python3-full
install_package python3-venv
install_package python3-docker
install_package python3-requests
install_package cron

# Create directories
INSTALL_DIR="/opt/pihole-docker-sync"
LOG_DIR="/var/log/pihole-docker-sync"
mkdir -p $INSTALL_DIR $LOG_DIR
chmod 755 $LOG_DIR

# Create Python script
cat > "$INSTALL_DIR/dns_sync.py" << 'EOF'
#!/usr/bin/env python3
import docker
import requests
import logging
import socket
import os
from typing import List, Dict, Optional

# Environment Configuration
DEFAULT_CONFIG = {
    'PIHOLE_HOST': 'http://192.168.20.193',
    'PIHOLE_TOKEN': '9a73fe4908f39d4afd6d36f52c77ac97c867f2ad34cfeada874f59b680ec44e8',
    'HOST_IP': None,  # Will be auto-detected if not set
    'LOG_LEVEL': 'INFO'
}

# Load configuration from environment variables or use defaults
CONFIG = {
    key: os.getenv(key, default_value)
    for key, default_value in DEFAULT_CONFIG.items()
}

class PiholeManager:
    def __init__(self, host: str, api_token: str):
        self.host = host.rstrip('/')
        self.api_token = api_token
        self.api_url = f"{self.host}/admin/api.php"

    def delete_dns_record(self, domain: str) -> bool:
        params = {
            'customdns': '',
            'auth': self.api_token,
            'action': 'delete',
            'domain': domain
        }
        
        try:
            response = requests.get(self.api_url, params=params)
            response.raise_for_status()
            return True
        except requests.exceptions.RequestException as e:
            logging.error(f"Failed to delete DNS record for {domain}: {str(e)}")
            return False

    def add_dns_record(self, domain: str, ip: str) -> bool:
        params = {
            'customdns': '',
            'auth': self.api_token,
            'action': 'add',
            'ip': ip,
            'domain': domain
        }
        
        try:
            response = requests.get(self.api_url, params=params)
            response.raise_for_status()
            return True
        except requests.exceptions.RequestException as e:
            logging.error(f"Failed to add DNS record for {domain}: {str(e)}")
            return False

class DockerManager:
    def __init__(self):
        try:
            self.client = docker.from_env()
        except docker.errors.DockerException as e:
            logging.error(f"Failed to connect to Docker: {str(e)}")
            raise

    def get_traefik_domains(self) -> List[str]:
        domains = []
        
        try:
            containers = self.client.containers.list(all=True)
            for container in containers:
                labels = container.labels
                
                for label, value in labels.items():
                    if 'traefik.http.routers' in label and 'rule' in label:
                        if 'Host(' in value or 'Host`' in value:
                            domain = value.split('Host(`')[1].split('`)')[0] if 'Host(`' in value else value.split('Host(')[1].split(')')[0]
                            if domain:
                                domains.append(domain)
        
        except docker.errors.APIError as e:
            logging.error(f"Failed to list containers: {str(e)}")
        
        return domains

def get_host_ip() -> str:
    host_ip = CONFIG['HOST_IP']
    if host_ip:
        return host_ip
        
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        host_ip = s.getsockname()[0]
        s.close()
        return host_ip
    except Exception as e:
        logging.error(f"Failed to determine host IP: {str(e)}")
        raise

def main():
    logging.basicConfig(
        level=getattr(logging, CONFIG['LOG_LEVEL'].upper()),
        format='%(asctime)s - %(levelname)s - %(message)s'
    )

    try:
        host_ip = get_host_ip()
        logging.info(f"Using host IP address: {host_ip}")

        docker_manager = DockerManager()
        pihole_manager = PiholeManager(CONFIG['PIHOLE_HOST'], CONFIG['PIHOLE_TOKEN'])

        domains = docker_manager.get_traefik_domains()

        if not domains:
            logging.info("No Traefik domains found in Docker containers")
            return

        for domain in domains:
            logging.info(f"Processing {domain} (pointing to {host_ip})")
            pihole_manager.delete_dns_record(domain)
            
            if pihole_manager.add_dns_record(domain, host_ip):
                logging.info(f"Successfully updated DNS record for {domain}")
            else:
                logging.error(f"Failed to update DNS record for {domain}")

    except Exception as e:
        logging.error(f"An unexpected error occurred: {str(e)}")
        exit(1)

if __name__ == "__main__":
    main()
EOF

chmod +x "$INSTALL_DIR/dns_sync.py"

# Create wrapper script
cat > "/usr/local/bin/pihole-docker-sync" << EOF
#!/bin/bash
source /etc/pihole-docker-sync.env
exec python3 $INSTALL_DIR/dns_sync.py "\$@"
EOF
chmod +x "/usr/local/bin/pihole-docker-sync"

# Create logrotate configuration
cat > "/etc/logrotate.d/pihole-docker-sync" << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# Add cron job
echo "*/5 * * * * root /usr/local/bin/pihole-docker-sync >> $LOG_DIR/sync.log 2>&1" > /etc/cron.d/pihole-docker-sync
chmod 644 /etc/cron.d/pihole-docker-sync

# Prompt for configuration
read -p "Enter Pi-hole host (default: http://192.168.20.193): " pihole_host
pihole_host=${pihole_host:-http://192.168.20.193}

read -p "Enter Pi-hole API token: " pihole_token
pihole_token=${pihole_token:-9a73fe4908f39d4afd6d36f52c77ac97c867f2ad34cfeada874f59b680ec44e8}

read -p "Enter host IP (leave blank for auto-detection): " host_ip

# Create environment file
cat > "/etc/pihole-docker-sync.env" << EOF
PIHOLE_HOST=$pihole_host
PIHOLE_TOKEN=$pihole_token
EOF

if [ ! -z "$host_ip" ]; then
    echo "HOST_IP=$host_ip" >> "/etc/pihole-docker-sync.env"
fi

chmod 600 "/etc/pihole-docker-sync.env"

# Test the script
echo -e "${YELLOW}Testing the script...${NC}"
/usr/local/bin/pihole-docker-sync

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo -e "Script location: ${YELLOW}$INSTALL_DIR/dns_sync.py${NC}"
    echo -e "Log location: ${YELLOW}$LOG_DIR/sync.log${NC}"
    echo -e "Environment file: ${YELLOW}/etc/pihole-docker-sync.env${NC}"
    echo -e "The script will run every 5 minutes via cron"
else
    echo -e "${RED}Script test failed. Please check the configuration and try again.${NC}"
fi

# Final instructions
echo -e "\n${YELLOW}To modify the configuration:${NC}"
echo "1. Edit the environment file: nano /etc/pihole-docker-sync.env"
echo "2. Edit the cron schedule: nano /etc/cron.d/pihole-docker-sync"
echo "3. View logs: tail -f $LOG_DIR/sync.log"
echo -e "\n${YELLOW}To run the script manually:${NC}"
echo "/usr/local/bin/pihole-docker-sync"