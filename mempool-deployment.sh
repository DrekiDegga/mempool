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

# Create a system user for Mempool
if ! id -u mempool > /dev/null 2>&1; then
  echo "Creating mempool user..."
  adduser --system --group --no-create-home mempool
fi

# Clone Mempool.space repository
echo "Cloning Mempool.space repository..."
mkdir -p /opt
cd /opt
git clone https://github.com/mempool/mempool.git
cd mempool
latestrelease=$(curl -s https://api.github.com/repos/mempool/mempool/releases/latest | grep tag_name | head -1 | cut -d '"' -f4)
git checkout "$latestrelease"
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
cd /opt/mempool/backend
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

# Install backend dependencies and build
echo "Installing backend dependencies..."
sudo -u mempool npm install
# Fix: Build the backend to generate dist/index.js
echo "Building backend..."
sudo -u mempool npm run build
# Check if build was successful
if [ ! -f /opt/mempool/backend/dist/index.js ]; then
  echo "Error: Backend build failed. The file /opt/mempool/backend/dist/index.js was not created."
  echo "Please check the output of 'npm run build' for errors."
  echo "You can try running the following commands manually:"
  echo "  cd /opt/mempool/backend"
  echo "  sudo -u mempool npm run build"
  exit 1
fi

# Build frontend
echo "Building frontend..."
cd ../frontend
sudo -u mempool npm install
sudo -u mempool cp mempool-frontend-config.sample.json mempool-frontend-config.json
sudo -u mempool npm run build
if [ ! -d dist/mempool ]; then
  echo "Error: Frontend build failed. The directory /opt/mempool/frontend/dist/mempool was not created."
  echo "Please check the output of 'npm run build' for errors."
  echo "You can try running the following commands manually:"
  echo "  cd /opt/mempool/frontend"
  echo "  sudo -u mempool npm run build"
  exit 1
fi
mkdir -p /var/www/html/mempool
cp -r dist/mempool/* /var/www/html/mempool/
chown -R www-data:www-data /var/www/html/mempool

# Configure Apache on the internal VM
echo "Configuring Apache on this VM..."
a2enmod proxy proxy_http
cat << EOF > /etc/apache2/sites-available/mempool.conf
