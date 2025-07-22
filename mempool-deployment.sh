#!/bin/bash

# Script to install Docker and deploy Mempool on Debian, using existing Bitcoin Core, Electrum server, and MariaDB,
# with Apache2 reverse proxy on another server and optional Tor hidden service using the official Tor repository.

# Exit on any error
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Default configuration values
DEFAULT_MARIADB_PORT=3306
DEFAULT_MEMPOOL_HTTP_PORT=8999
DEFAULT_ELECTRUM_PORT=50002
DEFAULT_BITCOIN_RPC_PORT=8332
DEFAULT_TOR_CONTROL_PORT=9051
DEFAULT_TOR_PORT=9050
DEFAULT_MEMPOOL_FRONTEND_PORT=4080
DEFAULT_MEMPOOL_DB_NAME="mempool"
DEFAULT_MEMPOOL_DB_USER="mempool"
DEFAULT_MEMPOOL_DB_PASSWORD="mempool"

# Function to print messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt for input with a default value, handling special characters
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    read -r -p "$prompt [$default]: " input
    eval $var_name="\${input:-\$default}"
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root or with sudo."
    exit 1
fi

# Update package lists
print_message "Updating package lists..."
apt-get update

# Install prerequisites
print_message "Installing prerequisites..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release netcat-openbsd

# Add Docker’s official GPG key
print_message "Adding Docker GPG key..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Set up Docker repository
print_message "Setting up Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
apt-get update

# Install Docker Engine and Docker Compose
print_message "Installing Docker and Docker Compose..."
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Start and enable Docker service
print_message "Starting and enabling Docker service..."
systemctl start docker
systemctl enable docker

# Verify Docker installation
print_message "Verifying Docker installation..."
docker --version
docker compose version

# Prompt for configuration details
print_message "Collecting configuration details..."

# Bitcoin Core
prompt_with_default "Enter Bitcoin Core RPC host (e.g., 192.168.1.100)" "127.0.0.1" BITCOIN_RPC_HOST
prompt_with_default "Enter Bitcoin Core RPC port" "$DEFAULT_BITCOIN_RPC_PORT" BITCOIN_RPC_PORT
prompt_with_default "Enter Bitcoin Core RPC username" "mempool" BITCOIN_RPC_USER
prompt_with_default "Enter Bitcoin Core RPC password" "mempool" BITCOIN_RPC_PASSWORD

# Electrum Server
prompt_with_default "Enter Electrum server host (e.g., electrum.degga.net)" "127.0.0.1" ELECTRUM_HOST
prompt_with_default "Enter Electrum server port" "$DEFAULT_ELECTRUM_PORT" ELECTRUM_PORT
prompt_with_default "Is Electrum server using TLS? (true/false)" "false" ELECTRUM_TLS_ENABLED

# MariaDB
prompt_with_default "Enter MariaDB host (e.g., 192.168.1.100)" "127.0.0.1" MARIADB_HOST
prompt_with_default "Enter MariaDB port" "$DEFAULT_MARIADB_PORT" MARIADB_PORT
prompt_with_default "Enter MariaDB database name" "$DEFAULT_MEMPOOL_DB_NAME" MARIADB_DATABASE
prompt_with_default "Enter MariaDB username" "$DEFAULT_MEMPOOL_DB_USER" MARIADB_USER
prompt_with_default "Enter MariaDB password" "$DEFAULT_MEMPOOL_DB_PASSWORD" MARIADB_PASSWORD

# Mempool ports
prompt_with_default "Enter Mempool backend HTTP port" "$DEFAULT_MEMPOOL_HTTP_PORT" MEMPOOL_HTTP_PORT
prompt_with_default "Enter Mempool frontend HTTP port" "$DEFAULT_MEMPOOL_FRONTEND_PORT" MEMPOOL_FRONTEND_PORT

# Apache2 reverse proxy details
prompt_with_default "Enter Apache2 server public domain or IP (e.g., mempool.example.com)" "mempool.local" APACHE_DOMAIN
prompt_with_default "Enter Mempool VM internal IP accessible by Apache2 server" "192.168.1.100" MEMPOOL_VM_IP

# Tor hidden service
prompt_with_default "Do you want to set up a Tor hidden service for Mempool? (yes/no)" "no" SETUP_TOR
if [ "$SETUP_TOR" = "yes" ]; then
    prompt_with_default "Enter Tor control port" "$DEFAULT_TOR_CONTROL_PORT" TOR_CONTROL_PORT
    prompt_with_default "Enter Tor proxy port" "$DEFAULT_TOR_PORT" TOR_PORT
fi

# Verify connectivity to dependencies
print_message "Verifying connectivity to dependencies..."

# MariaDB
if [ "$MARIADB_HOST" != "127.0.0.1" ] && [ "$MARIADB_HOST" != "localhost" ]; then
    print_message "Testing MariaDB connection to $MARIADB_HOST:$MARIADB_PORT..."
    if ! mysql -h "$MARIADB_HOST" -P "$MARIADB_PORT" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SELECT 1" 2>/dev/null; then
        print_error "Failed to connect to MariaDB at $MARIADB_HOST:$MARIADB_PORT with user $MARIADB_USER."
        print_error "Ensure the database is accessible and credentials are correct."
        exit 1
    fi
fi

# Bitcoin Core
print_message "Testing Bitcoin Core RPC connection to $BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT..."
if ! curl --user "$BITCOIN_RPC_USER:$BITCOIN_RPC_PASSWORD" --data-binary '{"jsonrpc":"1.0","id":"curltest","method":"getblockchaininfo","params":[]}' -H 'content-type:text/plain;' "http://$BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT/" 2>/dev/null | grep -q '"result"'; then
    print_error "Failed to connect to Bitcoin Core at $BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT."
    print_error "Check rpcuser, rpcpassword, and rpcallowip in bitcoin.conf."
    exit 1
fi

# Electrum
print_message "Testing Electrum connection to $ELECTRUM_HOST:$ELECTRUM_PORT..."
if ! nc -zv "$ELECTRUM_HOST" "$ELECTRUM_PORT" 2>/dev/null; then
    print_error "Failed to connect to Electrum at $ELECTRUM_HOST:$ELECTRUM_PORT."
    print_error "Ensure the Electrum server is running and accessible."
    exit 1
fi

# Set up Tor hidden service if requested
if [ "$SETUP_TOR" = "yes" ]; then
    print_message "Setting up Tor Project repository and installing latest Tor..."
    apt-get install -y apt-transport-https
    curl -fsSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --dearmor -o /usr/share/keyrings/tor-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/tor.list
    apt-get update
    apt-get install -y tor tor-geoipdb
    print_message "Configuring Tor hidden service directory..."
    mkdir -p /var/lib/tor/mempool_service
    chown debian-tor:debian-tor /var/lib/tor/mempool_service
    chmod 700 /var/lib/tor/mempool_service
    print_message "Creating /etc/tor/torrc..."
    cat > /etc/tor/torrc <<EOF
SocksPort $TOR_PORT
ControlPort $TOR_CONTROL_PORT
HiddenServiceDir /var/lib/tor/mempool_service/
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:$MEMPOOL_FRONTEND_PORT
EOF
    print_message "Validating Tor configuration..."
    if ! sudo -u debian-tor tor --verify-config -f /etc/tor/torrc; then
        print_error "Invalid Tor configuration in /etc/tor/torrc. Please check the file and fix syntax errors."
        print_error "View logs with: journalctl -u tor"
        print_error "Current torrc contents:"
        cat /etc/tor/torrc
        exit 1
    fi
    print_message "Restarting Tor service..."
    systemctl restart tor
    sleep 5
    if systemctl is-active --quiet tor; then
        print_message "Tor service is running."
        if [ -f /var/lib/tor/mempool_service/hostname ]; then
            print_message "Tor hidden service hostname:"
            cat /var/lib/tor/mempool_service/hostname
        else
            print_error "Tor hidden service hostname not found. Check Tor logs with: journalctl -u tor"
            print_error "Current torrc contents:"
            cat /etc/tor/torrc
            exit 1
        fi
    else
        print_error "Tor service failed to start. Check logs with: journalctl -u tor"
        print_error "Current torrc contents:"
        cat /etc/tor/torrc
        exit 1
    fi
fi

# Create docker-compose.yml for Mempool
print_message "Creating docker-compose.yml..."
mkdir -p /opt/mempool
cd /opt/mempool

cat > docker-compose.yml <<EOF
version: "3.7"
services:
  web:
    image: mempool/frontend:latest
    user: "1000:1000"
    restart: always
    stop_grace_period: 1m
    command: "nginx -g 'daemon off;'"
    ports:
      - "$MEMPOOL_FRONTEND_PORT:8080"
    environment:
      - FRONTEND_HTTP_PORT=8080
      - BACKEND_MAINNET_HTTP_HOST=api
  api:
    image: mempool/backend:latest
    user: "1000:1000"
    restart: always
    stop_grace_period: 1m
    command: "./start.sh"
    volumes:
      - ./data:/backend/cache
    environment:
      - MEMPOOL_BACKEND=electrum
      - ELECTRUM_HOST=$ELECTRUM_HOST
      - ELECTRUM_PORT=$ELECTRUM_PORT
      - ELECTRUM_TLS_ENABLED=$ELECTRUM_TLS_ENABLED
      - CORE_RPC_HOST=$BITCOIN_RPC_HOST
      - CORE_RPC_PORT=$BITCOIN_RPC_PORT
      - CORE_RPC_USERNAME=$BITCOIN_RPC_USER
      - CORE_RPC_PASSWORD="$(echo "$BITCOIN_RPC_PASSWORD" | sed -e 's/[\/&]/\\&/g')"
      - DATABASE_ENABLED=true
      - DATABASE_HOST=$MARIADB_HOST
      - DATABASE_PORT=$MARIADB_PORT
      - DATABASE_DATABASE=$MARIADB_DATABASE
      - DATABASE_USERNAME=$MARIADB_USER
      - DATABASE_PASSWORD="$(echo "$MARIADB_PASSWORD" | sed -e 's/[\/&]/\\&/g')"
      - MEMPOOL_HTTP_PORT=$MEMPOOL_HTTP_PORT
EOF

# If MariaDB is local, include the db service
if [ "$MARIADB_HOST" = "127.0.0.1" ] || [ "$MARIADB_HOST" = "localhost" ]; then
    print_message "Configuring local MariaDB in Docker..."
    cat >> docker-compose.yml <<EOF
  db:
    image: mariadb:10.5.8
    user: "1000:1000"
    restart: always
    stop_grace_period: 1m
    environment:
      - MYSQL_DATABASE=$MARIADB_DATABASE
      - MYSQL_USER=$MARIADB_USER
      - MYSQL_PASSWORD="$(echo "$MARIADB_PASSWORD" | sed -e 's/[\/&]/\\&/g')"
      - MYSQL_ROOT_PASSWORD="$(openssl rand -base64 12)"
    volumes:
      - ./mysql/data:/var/lib/mysql
EOF
fi

# Start Mempool
print_message "Starting Mempool with Docker Compose..."
docker compose up -d

# Generate Apache2 reverse proxy configuration
print_message "Generating Apache2 reverse proxy configuration for $APACHE_DOMAIN..."
cat > /opt/mempool/apache2-mempool.conf <<EOF
<VirtualHost *:443>
    ServerName $APACHE_DOMAIN
    SSLEngine on
    SSLCertificateFile /path/to/your/certificate.crt
    SSLCertificateKeyFile /path/to/your/private.key
    SSLCertificateChainFile /path/to/your/chain.pem

    ProxyPreserveHost On
    ProxyPass / http://$MEMPOOL_VM_IP:$MEMPOOL_FRONTEND_PORT/
    ProxyPassReverse / http://$MEMPOOL_VM_IP:$MEMPOOL_FRONTEND_PORT/

    <Location />
        Order allow,deny
        Allow from all
    </Location>

    ErrorLog \${APACHE_LOG_DIR}/mempool-error.log
    CustomLog \${APACHE_LOG_DIR}/mempool-access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName $APACHE_DOMAIN
    Redirect permanent / https://$APACHE_DOMAIN/
</VirtualHost>
EOF

print_message "Apache2 configuration generated at /opt/mempool/apache2-mempool.conf"
print_message "Copy this file to your Apache2 server (e.g., /etc/apache2/sites-available/mempool.conf)"
print_message "Update SSLCertificateFile, SSLCertificateKeyFile, and SSLCertificateChainFile paths"
print_message "Enable the site with: sudo a2ensite mempool && sudo systemctl reload apache2"

# Verify Mempool is running
print_message "Verifying Mempool is running..."
sleep 10
if docker ps | grep -q mempool; then
    print_message "Mempool containers are running."
    print_message "Testing web interface at http://127.0.0.1:$MEMPOOL_FRONTEND_PORT..."
    if curl -s --fail http://127.0.0.1:$MEMPOOL_FRONTEND_PORT >/dev/null; then
        print_message "Mempool web interface is accessible locally at http://$MEMPOOL_VM_IP:$MEMPOOL_FRONTEND_PORT"
        if [ "$SETUP_TOR" = "yes" ]; then
            print_message "Tor hidden service is set up. Access it via the .onion address shown above."
        fi
        print_message "Configure your Apache2 server to proxy HTTPS requests to http://$MEMPOOL_VM_IP:$MEMPOOL_FRONTEND_PORT"
    else
        print_error "Mempool web interface is not accessible at http://127.0.0.1:$MEMPOOL_FRONTEND_PORT"
        print_error "Check container logs with: docker compose logs"
        exit 1
    fi
else
    print_error "Mempool containers failed to start. Check logs with: docker compose logs"
    exit 1
fi

print_message "Deployment complete!"
