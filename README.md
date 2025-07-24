# Mempool Deployment Script for Debian

This Bash script automates the deployment of Mempool on a Debian-based server. It installs Docker, deploys Mempool with Docker Compose, and connects to an existing Bitcoin Core node, Electrum server, and MariaDB database. It also supports generating an Apache2 reverse proxy configuration for another server and an optional Tor hidden service using the official Tor repository.

## Features
- Installs Docker and Docker Compose.
- Configures Mempool with user-provided settings for Bitcoin Core, Electrum, and MariaDB.
- Supports local or remote MariaDB instances.
- Generates Apache2 reverse proxy configuration for HTTPS access.
- Optional Tor hidden service setup for anonymous access.
- Verifies connectivity to dependencies with clear error messages.

## Prerequisites
- Debian-based server with root or sudo access.
- Running Bitcoin Core node with RPC enabled (`rpcuser`, `rpcpassword`, `rpcallowip` configured).
- Accessible Electrum server (e.g., Electrs or Fulcrum).
- MariaDB instance (local or remote) with database and user credentials.
- Optional: Apache2 server for reverse proxy with HTTPS certificates.
- Network access to Bitcoin Core, Electrum, and MariaDB.
- Optional: Internet access for Tor hidden service setup.

## Installation
1. Clone this repository: git clone https://github.com/your-username/mempool-deployment.git
2. Navigate to the directory: cd mempool-deployment
3. Make the script executable: chmod +x deploy-mempool.sh
4. Run the script as root: sudo ./deploy-mempool.sh

## Usage
The script prompts for configuration details, including Bitcoin Core RPC, Electrum server, MariaDB, Mempool ports, Apache2 domain/IP, and Tor hidden service (optional). It then:
- Installs prerequisites (Docker, Docker Compose, mariadb-client).
- Verifies connectivity to dependencies.
- Sets up Tor hidden service (if selected).
- Creates a docker-compose.yml in /opt/mempool.
- Starts Mempool via Docker Compose.
- Generates Apache2 reverse proxy configuration.
- Verifies Mempool accessibility.

### Outputs
- Docker Compose file: /opt/mempool/docker-compose.yml
- Apache2 configuration: /opt/mempool/apache2-mempool.conf
- Tor hidden service (if enabled): .onion address in /var/lib/tor/mempool_service/hostname

## Post-Installation
- Apache2: Copy /opt/mempool/apache2-mempool.conf to your Apache2 server (/etc/apache2/sites-available/mempool.conf), update SSL certificate paths, and enable with: sudo a2ensite mempool && sudo systemctl reload apache2
- Access Mempool: Locally at http://<MEMPOOL_VM_IP>:<frontend-port>, via Apache2 at https://<APACHE_DOMAIN>, or via Tor .onion address (if enabled).
- Troubleshooting: Check Docker logs (docker compose logs in /opt/mempool) or Tor logs (journalctl -u tor).

## Security Considerations
- Restrict Bitcoin Core `rpcallowip` to the Mempool server’s IP.
- Use strong MariaDB credentials and restrict access.
- Secure Apache2 with valid SSL certificates (e.g., Let’s Encrypt).
- For Tor, secure /var/lib/tor/mempool_service and monitor logs.
- Configure a firewall (e.g., ufw) to allow only necessary ports.

## Troubleshooting
- Connectivity issues: Verify Bitcoin Core, Electrum, and MariaDB are accessible. Check firewall and credentials.
- Docker issues: Confirm Docker is installed (docker --version, docker compose version) and containers are running (docker ps).
- Tor issues: Check /etc/tor/torrc and logs (journalctl -u tor).
- Apache2 issues: Verify SSL paths and reverse proxy settings.

