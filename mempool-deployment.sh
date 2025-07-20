#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g., using sudo)"
  exit 1
fi

# Prompt user for deployment options with defaults
echo "Please provide the following information. Press Enter to accept defaults."

read -p "Database host [localhost]: " db_host
db_host=${db_host:-localhost}

if [ "$db_host" == "localhost" ]; then
  db_port=3306
  db_name="mempool"
  db_user="mempool"
  db_pass=$(openssl rand -base64 12)
  echo "Generated database password: $db_pass"
else
  read -p "Database port [3306]: " db_port
  db_port=${db_port:-3306}
  read -p "Database name [mempool]: " db_name
  db_name=${db_name:-mempool}
  read -p "Database username: " db_user
  read -s -p "Database password: " db_pass
  echo
fi

read -p "Bitcoin RPC host [127.0.0.1]: " bitcoin_rpc_host
bitcoin_rpc_host=${bitcoin_rpc_host:-127.0.0.1}
read -p "Bitcoin RPC port [8332]: " bitcoin_rpc_port
bitcoin_rpc_port=${bitcoin_rpc_port:-8332}
read -p "Bitcoin RPC username: " bitcoin_rpc_user
read -s -p "Bitcoin RPC password: " bitcoin_rpc_pass
echo

read -p "Electrum host [127.0.0.1]: " electrum_host
electrum_host=${electrum_host:-127.0.0.1}
read -p "Electrum port [50002]: " electrum_port
electrum_port=${electrum_port:-50002}
read -p "Electrum TLS enabled [true]: " electrum_tls
electrum_tls=${electrum_tls:-true}

read -p "Set up TOR hidden service? [no]: " tor_enabled
tor_enabled=${tor_enabled:-no}

# Install required packages
echo "Installing necessary packages..."
apt-get update
apt-get install -y git curl apache2

# Install MariaDB server if database is local
if [ "$db_host" == "localhost" ]; then
  apt-get install -y mariadb-server
fi

# Install TOR if enabled
if [ "$tor_enabled" == "yes" ]; then
  apt-get install -y tor
fi

# Install Node.js LTS from NodeSource
echo "Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Create mempool user with home directory and no login shell
if ! id -u mempool > /dev/null 2>&1; then
  echo "Creating mempool user with home directory and no login shell..."
  useradd -m -s /bin/false mempool
fi

# Install Rust for mempool user
echo "Installing Rust for mempool user..."
sudo -u mempool bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'

# Set default Rust toolchain
echo "Setting default Rust toolchain to 1.84..."
sudo -u mempool bash -c 'source $HOME/.cargo/env && rustup default 1.84'

# Verify Rust installation
echo "Verifying Rust installation..."
sudo -u mempool bash -c 'source $HOME/.cargo/env && cargo --version'

# Clone Mempool repository as mempool user
echo "Cloning Mempool.space repository..."
sudo -u mempool git clone https://github.com/mempool/mempool.git /opt/mempool

# Set up database if local
if [ "$db_host" == "localhost" ]; then
  echo "Setting up local MariaDB database..."
  systemctl start mariadb
  systemctl enable mariadb
  mysql -e "CREATE DATABASE $db_name;"
  mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';"
  mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
fi

# Configure Mempool backend
echo "Configuring Mempool backend..."
sudo -u mempool bash -c "cat << EOF > /opt/mempool/backend/mempool-config.json
{
  \"MEMPOOL\": {
    \"NETWORK\": \"mainnet\",
    \"BACKEND\": \"electrum\",
    \"HTTP_PORT\": 8999,
    \"SPAWN_CLUSTER_PROCS\": 0,
    \"API_URL_PREFIX\": \"/api/v1/\",
    \"POLL_RATE_MS\": 2000,
    \"CACHE_DIR\": \"./cache\",
    \"CLEAR_PROTECTION_MINUTES\": 20,
    \"RECOMMENDED_FEE_PERCENTILE\": 50,
    \"BLOCK_WEIGHT_UNITS\": 4000000,
    \"INITIAL_BLOCKS_AMOUNT\": 8,
    \"MEMPOOL_BLOCKS_AMOUNT\": 8,
    \"PRICE_FEED_UPDATE_INTERVAL\": 3600,
    \"USE_SECOND_NODE_FOR_MINFEE\": false,
    \"EXTERNAL_ASSETS\": []
  },
  \"CORE_RPC\": {
    \"HOST\": \"$bitcoin_rpc_host\",
    \"PORT\": $bitcoin_rpc_port,
    \"USERNAME\": \"$bitcoin_rpc_user\",
    \"PASSWORD\": \"$bitcoin_rpc_pass\"
  },
  \"ELECTRUM\": {
    \"HOST\": \"$electrum_host\",
    \"PORT\": $electrum_port,
    \"TLS_ENABLED\": $electrum_tls
  },
  \"DATABASE\": {
    \"ENABLED\": true,
    \"HOST\": \"$db_host\",
    \"PORT\": $db_port,
    \"USERNAME\": \"$db_user\",
    \"PASSWORD\": \"$db_pass\",
    \"DATABASE\": \"$db_name\"
  },
  \"SOCKS5PROXY\": {
    \"ENABLED\": false
  },
  \"PRICE_DATA_SERVER\": {
    \"TOR_URL\": \"http://wizpriceje6q5tdrxkyiazsgu7irquiqjy2dptezqhrtu7l2qelqktid.onion/getAllMarketPrices\"
  }
}
EOF"

# Clean up existing node_modules
echo "Cleaning up existing node_modules..."
rm -rf /opt/mempool/backend/node_modules /opt/mempool/backend/package-lock.json

# Install and build backend with Rust environment
echo "Installing backend dependencies..."
sudo -u mempool bash -c 'source $HOME/.cargo/env && cd /opt/mempool/backend && npm install'

echo "Building backend..."
sudo -u mempool bash -c 'source $HOME/.cargo/env && cd /opt/mempool/backend && npm run build'

# Build frontend
echo "Building frontend..."
sudo -u mempool bash -c 'cd /opt/mempool/frontend && npm install'
sudo -u mempool bash -c 'cd /opt/mempool/frontend && npm run build'

# Copy frontend to Apache directory
mkdir -p /var/www/html/mempool
cp -r /opt/mempool/frontend/dist/mempool/* /var/www/html/mempool/
chown -R www-data:www-data /var/www/html/mempool

# Configure Apache
echo "Configuring Apache..."
a2enmod proxy proxy_http
cat << EOF > /etc/apache2/sites-available/mempool.conf
<VirtualHost *:80>
    ServerName mempool.local
    DocumentRoot /var/www/html/mempool

    <Directory /var/www/html/mempool>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ProxyPass /api http://localhost:8999/api
    ProxyPassReverse /api http://localhost:8999/api
</VirtualHost>
EOF
a2ensite mempool
systemctl reload apache2

# Create systemd service for Mempool backend
echo "Creating systemd service..."
cat << EOF > /etc/systemd/system/mempool.service
[Unit]
Description=Mempool.space Backend
After=network.target

[Service]
WorkingDirectory=/opt/mempool/backend
ExecStart=/usr/bin/node --max-old-space-size=2048 dist/index.js
User=mempool
Restart=on-failure
RestartSec=600

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mempool
systemctl start mempool

# Set up TOR hidden service if enabled
if [ "$tor_enabled" == "yes" ]; then
  echo "Configuring TOR hidden service..."
  echo "HiddenServiceDir /var/lib/tor/mempool/" >> /etc/tor/torrc
  echo "HiddenServicePort 80 127.0.0.1:80" >> /etc/tor/torrc
  systemctl restart tor
  sleep 5
  onion_address=$(cat /var/lib/tor/mempool/hostname)
fi

# Get internal IP for summary
internal_ip=$(hostname -I | awk '{print $1}')

# Summary
echo ""
echo "Mempool.space Deployment Summary"
echo "================================="
echo "Installation Path: /opt/mempool"
echo "Frontend Access: http://$internal_ip/mempool"
if [ "$tor_enabled" == "yes" ]; then
  echo "TOR Hidden Service: http://$onion_address"
fi
echo "Backend Service: mempool.service"
echo "Database: $db_host:$db_port, Database Name: $db_name, User: $db_user"
if [ "$db_host" == "localhost" ]; then
  echo "Database Password: $db_pass (generated)"
else
  echo "Database Password: (as provided)"
fi
echo "Bitcoin RPC: $bitcoin_rpc_host:$bitcoin_rpc_port, User: $bitcoin_rpc_user"
echo "Electrum Server: $electrum_host:$electrum_port, TLS: $electrum_tls"
echo ""
echo "To update Mempool.space:"
echo "  cd /opt/mempool"
echo "  git pull"
echo "  cd backend"
echo "  sudo -u mempool bash -c 'source \$HOME/.cargo/env && npm install'"
echo "  sudo -u mempool bash -c 'source \$HOME/.cargo/env && npm run build'"
echo "  cd ../frontend"
echo "  sudo -u mempool bash -c 'npm install'"
echo "  sudo -u mempool bash -c 'npm run build'"
echo "  cp -r dist/mempool/* /var/www/html/mempool/"
echo "  systemctl restart mempool"
echo ""
echo "Troubleshooting:"
echo "  systemctl status mempool"
echo "  systemctl status apache2"
if [ "$tor_enabled" == "yes" ]; then
  echo "  systemctl status tor"
fi
if [ "$db_host" == "localhost" ]; then
  echo "  systemctl status mariadb"
fi
echo "  journalctl -u mempool"
echo "  journalctl -u apache2"
