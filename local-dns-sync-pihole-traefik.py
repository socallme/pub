#!/usr/bin/env python3
import docker
import requests
import logging
import socket
import os
from typing import List, Dict, Optional

# Environment Configuration
# Override these values or set environment variables
DEFAULT_CONFIG = {
    'PIHOLE_HOST': 'http://192.168.20.193',
    'PIHOLE_TOKEN': 'xx',
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
        """Delete a DNS record from Pi-hole."""
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
        """Add a DNS record to Pi-hole."""
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
        """Get all domains from Traefik labels in Docker containers."""
        domains = []
        
        try:
            containers = self.client.containers.list(all=True)
            for container in containers:
                labels = container.labels
                
                # Look for Traefik router rules
                for label, value in labels.items():
                    if 'traefik.http.routers' in label and 'rule' in label:
                        # Parse the Host rule
                        if 'Host(' in value or 'Host`' in value:
                            # Extract domain from Host rule
                            domain = value.split('Host(`')[1].split('`)')[0] if 'Host(`' in value else value.split('Host(')[1].split(')')[0]
                            if domain:
                                domains.append(domain)
        
        except docker.errors.APIError as e:
            logging.error(f"Failed to list containers: {str(e)}")
        
        return domains

def get_host_ip() -> str:
    """Get the IP address of the host machine."""
    host_ip = CONFIG['HOST_IP']
    if host_ip:
        return host_ip
        
    try:
        # Try to get the IP by creating a temporary socket connection
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        host_ip = s.getsockname()[0]
        s.close()
        return host_ip
    except Exception as e:
        logging.error(f"Failed to determine host IP: {str(e)}")
        raise

def main():
    # Configure logging
    logging.basicConfig(
        level=getattr(logging, CONFIG['LOG_LEVEL'].upper()),
        format='%(asctime)s - %(levelname)s - %(message)s'
    )

    try:
        # Get the host IP address
        host_ip = get_host_ip()
        logging.info(f"Using host IP address: {host_ip}")

        # Initialize managers
        docker_manager = DockerManager()
        pihole_manager = PiholeManager(CONFIG['PIHOLE_HOST'], CONFIG['PIHOLE_TOKEN'])

        # Get all Traefik domains
        domains = docker_manager.get_traefik_domains()

        if not domains:
            logging.info("No Traefik domains found in Docker containers")
            return

        # Process each domain
        for domain in domains:
            logging.info(f"Processing {domain} (pointing to {host_ip})")

            # Always try to delete first
            pihole_manager.delete_dns_record(domain)
            
            # Add the new record
            if pihole_manager.add_dns_record(domain, host_ip):
                logging.info(f"Successfully updated DNS record for {domain}")
            else:
                logging.error(f"Failed to update DNS record for {domain}")

    except Exception as e:
        logging.error(f"An unexpected error occurred: {str(e)}")
        exit(1)

if __name__ == "__main__":
    main()