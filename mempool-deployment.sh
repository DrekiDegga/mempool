#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g., using sudo)"
  exit 1
fi

# Prompt user for deployment options with sane defaults
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

# Install MariaDB server if database is on localhost
if [ "$db_host" == "localhost" ]; then
  apt-get install -y mariadb-server
fi

# Install TOR if enabled
if [ "$tor_enabled" == "yes" ]; then
  apt-get install -y tor
fi

# Install Node.js LTS from NodeSource
echo "Installing Node.js LTS from NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Create a system user for Mempool with a home directory
if ! id -u mempool > /dev/null 2>&1; then
  echo "Creating mempool user with home directory..."
  mkdir -p /opt/mempool-home
  adduser --system --group --home /opt/mempool-home --no-create-home mempool
  chown -R mempool:mempool /opt/mempool-home
fi

# Set up tools directory for Rust and npm cache
echo "Setting up tools directory..."
mkdir -p /opt/mempool-tools/rustup /opt/mempool-tools/cargo /opt/mempool-tools/.npm-cache
chown -R mempool:mempool /opt/mempool-tools

# Install Rust for mempool user with explicit environment variables
echo "Installing Rust..."
sudo -u mempool env HOME=/opt/mempool-home RUSTUP_HOME=/opt/mempool-tools/rustup CARGO_HOME=/opt/mempool-tools/cargo \
  bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'

# Set Rust version to 1.84
sudo -u mempool env HOME=/opt/mempool-home RUSTUP_HOME=/opt/mempool-tools/rustup CARGO_HOME=/opt/mempool-tools/cargo \
  bash -c '/opt/mempool-tools/cargo/bin/rustup install 1.84'
sudo -u mempool env HOME=/opt/mempool-home RUSTUP_HOME=/opt/mempool-tools/rustup CARGO_HOME=/opt/mempool-tools/cargo \
  bash -c '/opt/mempool-tools/cargo/bin/rustup default 1.84'

# Verify Rust installation
if ! sudo -u mempool env HOME=/opt/mempool-home PATH=/opt/mempool-tools/cargo/bin:$PATH cargo --version; then
  echo "Error: Rust installation failed."
  exit 1
fi

# Clone Mempool.space repository
echo "Cloning Mempool.space repository..."
# Clean up existing /opt/mempool if it exists
if [ -d /opt/mempool ]; then
  echo "Removing existing /opt/mempool directory..."
  rm -rf /opt/mempool
fi
mkdir -p /opt
cd /opt || { echo "Error: Failed to change to /opt directory."; exit 1; }
git clone https://github.com/mempool/mempool.git
if [ $? -ne 0 ]; then
  echo "Error: Failed to clone Mempool repository."
  exit 1
fi
cd mempool || { echo "Error: Failed to change to /opt/mempool directory."; exit 1; }
latestrelease=$(curl -s https://api.github.com/repos/mempool/mempool/releases/latest | grep tag_name | head -1 | cut -d '"' -f4)
if [ -z "$latestrelease" ]; then
  echo "Error: Failed to fetch latest Mempool release tag."
  exit 1
fi
git checkout "$latestrelease"
if [ $? -ne 0 ]; then
  echo "Error: Failed to checkout release $latestrelease."
  exit 1
fi
chown -R mempool:mempool /opt/mempool

# Set up database if localhost
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
cd /opt/mempool/backend || { echo "Error: Failed to change to /opt/mempool/backend directory."; exit 1; }
cat << EOF > mempool-config.json
{
  "MEMPOOL": {
    "NETWORK": "mainnet",
    "BACKEND": "electrum",
    "HTTP_PORT": 8999,
    "SPAWN_CLUSTER_PROCS": 0,
    "API_URL_PREFIX": "/api/v1/",
    "POLL_RATE_MS": 2000,
    "CACHE_DIR": "./cache",
    "CLEAR_PROTECTION_MINUTES": 20,
    "RECOMMENDED_FEE_PERCENTILE": 50,
    "BLOCK_WEIGHT_UNITS": 4000000,
    "INITIAL_BLOCKS_AMOUNT": 8,
    "MEMPOOL_BLOCKS_AMOUNT": 8,
    "PRICE_FEED_UPDATE_INTERVAL": 3600,
    "USE_SECOND_NODE_FOR_MINFEE": false,
    "EXTERNAL_ASSETS": []
  },
  "CORE_RPC": {
    "HOST": "$bitcoin_rpc_host",
    "PORT": $bitcoin_rpc_port,
    "USERNAME": "$bitcoin_rpc_user",
    "PASSWORD": "$bitcoin_rpc_pass"
  },
  "ELECTRUM": {
    "HOST": "$electrum_host",
    "PORT": $electrum_port,
    "TLS_ENABLED": $electrum_tls
  },
  "DATABASE": {
    "ENABLED": true,
    "HOST": "$db_host",
    "PORT": $db_port,
    "USERNAME": "$db_user",
    "PASSWORD": "$db_pass",
    "DATABASE": "$db_name"
  },
  "SOCKS5PROXY": {
    "ENABLED": false
  },
  "PRICE_DATA_SERVER": {
    "TOR_URL": "http://wizpriceje6q5tdrxkyiazsgu7irquiqjy2dptezqhrtu7l2qelqktid.onion/getAllMarketPrices"
  }
}
EOF

# Clean up any existing node_modules to avoid corruption
echo "Cleaning up existing node_modules..."
rm -rf /opt/mempool/backend/node_modules /opt/mempool/backend/package-lock.json

# Install backend dependencies
echo "Installing backend dependencies..."
sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:$PATH; cd /opt/mempool/backend && npm install --cache=/opt/mempool-tools/.npm-cache'
if [ $? -ne 0 ]; then
  echo "Error: npm install failed for backend. Check the output above for details."
  echo "Try running manually:"
  echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cd /opt/mempool/backend && npm install --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
  exit 1
fi

# Ensure typescript is installed
echo "Ensuring typescript is installed..."
sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:$PATH; cd /opt/mempool/backend && npm install typescript --cache=/opt/mempool-tools/.npm-cache'
if [ ! -f /opt/mempool/backend/node_modules/typescript/bin/tsc ]; then
  echo "Error: TypeScript not installed correctly."
  echo "Try running manually:"
  echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cd /opt/mempool/backend && npm install typescript --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
  exit 1
fi

# Build backend
echo "Building backend..."
sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:$PATH; cd /opt/mempool/backend && npm run build --cache=/opt/mempool-tools/.npm-cache'
if [ ! -f /opt/mempool/backend/dist/index.js ]; then
  echo "Error: Backend build failed. The file /opt/mempool/backend/dist/index.js was not created."
  echo "Try running manually:"
  echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cd /opt/mempool/backend && npm run build --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
  exit 1
fi

# Build frontend
echo "Building frontend..."
cd /opt/mempool/frontend || { echo "Error: Failed to change to /opt/mempool/frontend directory."; exit 1; }
rm -rf node_modules package-lock.json
sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:$PATH; cd /opt/mempool/frontend && npm install --cache=/opt/mempool-tools/.npm-cache'
if [ $? -ne 0 ]; then
  echo "Error: npm install failed for frontend. Check the output above for details."
  echo "Try running manually:"
  echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cd /opt/mempool/frontend && npm install --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
  exit 1
fi
sudo -u mempool cp mempool-frontend-config.sample.json mempool-frontend-config.json
sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:$PATH; cd /opt/mempool/frontend && npm run build --cache=/opt/mempool-tools/.npm-cache'
if [ ! -d dist/mempool ]; then
  echo "Error: Frontend build failed. The directory /opt/mempool/frontend/dist/mempool was not created."
  echo "Try running manually:"
  echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cd /opt/mempool/frontend && npm run build --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
  exit 1
fi
mkdir -p /var/www/html/mempool
cp -r dist/mempool/* /var/www/html/mempool/
chown -R www-data:www-data /var/www/html/mempool

# Configure Apache on the internal VM
echo "Configuring Apache on this VM..."
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
echo "Creating systemd service for Mempool backend..."
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

# Get the internal IP for summary
internal_ip=$(hostname -I | awk '{print $1}')

# Summary
echo ""
echo "Mempool.space Deployment Summary"
echo "================================="
echo "Installation Path: /opt/mempool"
echo "Frontend Access (Internal): http://$internal_ip/mempool"
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
echo "Services Installed:"
echo "- mempool.service (Mempool backend)"
echo "- apache2 (Serving frontend and proxying API on this VM)"
if [ "$tor_enabled" == "yes" ]; then
  echo "- tor (TOR hidden service)"
fi
if [ "$db_host" == "localhost" ]; then
  echo "- mariadb (Local database)"
fi
echo ""
echo "Public Access Configuration"
echo "---------------------------"
echo "To serve Mempool.space publicly via your existing Apache2 server, add this to its configuration:"
echo ""
echo "<VirtualHost *:443>"
echo "    ServerName mempool.example.com"
echo "    SSLEngine on"
echo "    SSLCertificateFile /path/to/cert.pem"
echo "    SSLCertificateKeyFile /path/to/key.pem"
echo ""
echo "    ProxyPass / http://$internal_ip:80/"
echo "    ProxyPassReverse / http://$internal_ip:80/"
echo "</VirtualHost>"
echo "Adjust ServerName and SSL certificate paths as needed."
echo ""
echo "Recommendations"
echo "--------------"
echo "To update Mempool.space:"
echo "  cd /opt/mempool"
echo "  git pull"
echo "  cd backend"
echo "  rm -rf node_modules package-lock.json"
echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm install --cache=/opt/mempool-tools/.npm-cache'"
echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm run build --cache=/opt/mempool-tools/.npm-cache'"
echo "  cd ../frontend"
echo "  rm -rf node_modules package-lock.json"
echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm install --cache=/opt/mempool-tools/.npm-cache'"
echo "  sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm run build --cache=/opt/mempool-tools/.npm-cache'"
echo "  cp -r dist/mempool/* /var/www/html/mempool/"
echo "  systemctl restart mempool"
echo ""
echo "Troubleshooting Tips"
echo "--------------------"
echo "If the backend fails to start or build fails:"
echo "  - Check npm cache permissions:"
echo "    ls -ld /opt/mempool-tools/.npm-cache"
echo "    chown mempool:mempool /opt/mempool-tools/.npm-cache"
echo "  - Check Rust installation:"
echo "    sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; cargo --version'"
echo "  - Re-run backend installation and build:"
echo "    cd /opt/mempool/backend"
echo "    rm -rf node_modules package-lock.json"
echo "    sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm install --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
echo "    sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm install typescript --cache=/opt/mempool-tools/.npm-cache'"
echo "    sudo -u mempool bash -c 'export PATH=/opt/mempool-tools/cargo/bin:\$PATH; npm run build --cache=/opt/mempool-tools/.npm-cache --loglevel=verbose'"
echo "Check service statuses:"
echo "  systemctl status mempool"
echo "  systemctl status apache2"
if [ "$tor_enabled" == "yes" ]; then
  echo "  systemctl status tor"
fi
if [ "$db_host" == "localhost" ]; then
  echo "  systemctl status mariadb"
fi
echo "View logs:"
echo "  journalctl -u mempool"
echo "  journalctl -u apache2"
if [ "$tor_enabled" == "yes" ]; then
  echo "  journalctl -u tor"
fi
if [ "$db_host" == "localhost" ]; then
  echo "  journalctl -u mariadb"
fi
echo "Ensure your Bitcoin node and Electrum server are running and accessible."
if [ "$db_host" != "localhost" ]; then
  echo "Verify that the MariaDB server at $db_host allows connections from this VM."
fi
echo "Check disk space and memory:"
echo "  df -h"
echo "  free -m"

# Check service statuses and print recent logs
echo ""
echo "Service Status Checks"
echo "====================="
echo "Mempool Backend:"
systemctl status mempool --no-pager
echo ""
echo "Apache2:"
systemctl status apache2 --no-pager
echo ""
if [ "$tor_enabled" == "yes" ]; then
  echo "TOR:"
  systemctl status tor --no-pager
  echo ""
fi
if [ "$db_host" == "localhost" ]; then
  echo "MariaDB:"
  systemctl status mariadb --no-pager
  echo ""
fi

echo "Recent Logs"
echo "==========="
echo "Mempool Backend:"
journalctl -u mempool --no-pager -n 20
echo ""
echo "Apache2:"
journalctl -u apache2 --no-pager -n 20
echo ""
if [ "$tor_enabled" == "yes" ]; then
  echo "TOR:"
  journalctl -u tor --no-pager -n 20
  echo ""
fi
if [ "$db_host" == "localhost" ]; then
  echo "MariaDB:"
  journalctl -u mariadb --no-pager -n 20
  echo ""
fi
