#!/bin/bash

# Exit on any error
set -e

# Variables to store user choices and inputs
vm_ip=$(hostname -I | awk '{print $1}')  # Get the VM's IP address

# Function to prompt for yes/no and return true/false
prompt_yes_no() {
    local prompt="$1"
    while true; do
        read -p "$prompt (y/n): " choice
        case "$choice" in
            y|Y) return 0;;
            n|N) return 1;;
            *) echo "Please enter y or n.";;
        esac
    done
}

# Function to set up Bitcoin Knots
setup_bitcoin_knots() {
    echo "Setting up Bitcoin Knots..."
    sudo apt install -y build-essential libtool autotools-dev automake pkg-config bsdmainutils python3 libevent-dev libboost-system-dev libboost-filesystem-dev libboost-chrono-dev libboost-test-dev libboost-thread-dev libsqlite3-dev libminiupnpc-dev libzmq3-dev
    cd ~
    git clone https://github.com/bitcoinknots/bitcoin.git bitcoin-knots
    cd bitcoin-knots
    ./autogen.sh
    ./configure
    make -j$(nproc)
    sudo make install
    mkdir -p ~/.bitcoin
    cat <<EOF > ~/.bitcoin/bitcoin.conf
rpcuser=$btc_user
rpcpassword=$btc_pass
rpcport=$btc_port
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
server=1
txindex=1
daemon=1
EOF
    bitcoind &
    sleep 5  # Wait for bitcoind to start
    echo "Bitcoin Knots installed and running."
    btc_host="127.0.0.1"
}

# Function to set up Fulcrum
setup_fulcrum() {
    echo "Setting up Fulcrum..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    cd ~
    git clone https://github.com/cculianu/Fulcrum.git
    cd Fulcrum
    cargo build --release
    mkdir -p ~/fulcrum
    cp target/release/Fulcrum ~/fulcrum/
    cores=$(nproc)
    cat <<EOF > ~/fulcrum/fulcrum.conf
rpcuser=fulcrum_user
rpcpassword=fulcrum_pass
rpcport=50002
bitcoind=$btc_host:$btc_port
bitcoind_user=$btc_user
bitcoind_pass=$btc_pass
worker_threads=$cores
EOF
    cd ~/fulcrum
    ./Fulcrum &
    sleep 5
    echo "Fulcrum installed and running on port 50002."
}

# Function to set up MariaDB locally
setup_mariadb() {
    echo "Setting up MariaDB locally..."
    sudo apt install -y mariadb-server
    sudo mysql_secure_installation <<EOF

y
root_password
root_password
y
y
y
y
EOF
    sudo mysql -u root -proot_password <<EOF
CREATE DATABASE mempool;
CREATE USER 'mempool_user'@'localhost' IDENTIFIED BY 'mempool_pass';
GRANT ALL PRIVILEGES ON mempool.* TO 'mempool_user'@'localhost';
FLUSH PRIVILEGES;
EOF
    db_host="127.0.0.1"
    db_port=3306
    db_user="mempool_user"
    db_pass="mempool_pass"
    db_name="mempool"
    echo "MariaDB installed and configured."
}

# Function to set up Mempool
setup_mempool() {
    echo "Setting up Mempool..."
    sudo apt install -y nodejs npm
    sudo npm install -g pm2
    sudo npm install -g http-server
    cd ~
    git clone https://github.com/mempool/mempool.git
    cd mempool/backend
    npm install
    cd ../frontend
    npm install
    npm run build
    cd ..

    # Determine backend type
    if [ "$setup_fulcrum" = "true" ] || [ -n "$electrum_host" ]; then
        backend="electrum"
        if [ "$setup_fulcrum" = "true" ]; then
            electrum_host="127.0.0.1"
            electrum_port=50002
        fi
    else
        backend="core"
    fi

    # Generate Mempool config
    cat <<EOF > backend/config.json
{
  "MEMPOOL": {
    "NETWORK": "mainnet",
    "BACKEND": "$backend",
    "HTTP_PORT": 8999
  },
  "CORE_RPC": {
    "HOST": "$btc_host",
    "PORT": $btc_port,
    "USERNAME": "$btc_user",
    "PASSWORD": "$btc_pass"
  },
  "ELECTRUM": {
    "HOST": "$electrum_host",
    "PORT": $electrum_port,
    "TLS_ENABLED": true
  },
  "DATABASE": {
    "ENABLED": true,
    "HOST": "$db_host",
    "PORT": $db_port,
    "USERNAME": "$db_user",
    "PASSWORD": "$db_pass",
    "DATABASE": "$db_name"
  }
}
EOF
    cd backend
    pm2 start npm --name "mempool-backend" -- run start
    cd ../frontend
    pm2 start http-server --name "mempool-frontend" -- dist/mempool --port 4200
    echo "Mempool installed and running locally on http://$vm_ip:4200"
}

# Function to set up Apache2 locally
setup_apache() {
    echo "Setting up Apache2 locally..."
    sudo apt install -y apache2
    sudo a2enmod proxy proxy_http rewrite
    cat <<EOF | sudo tee /etc/apache2/sites-available/mempool.conf
<VirtualHost *:80>
    ServerName $domain_name
    ProxyPass /api http://127.0.0.1:8999/
    ProxyPassReverse /api http://127.0.0.1:8999/
    ProxyPass / http://127.0.0.1:4200/
    ProxyPassReverse / http://127.0.0.1:4200/
</VirtualHost>
EOF
    sudo a2ensite mempool.conf
    sudo systemctl reload apache2

    if [ "$setup_letsencrypt" = "true" ]; then
        sudo apt install -y certbot python3-certbot-apache
        sudo certbot --apache -d "$domain_name" --non-interactive --agree-tos --email user@example.com
        echo "Let's Encrypt certificate set up for $domain_name."
    fi
    echo "Apache2 configured to serve Mempool locally."
}

# Function to set up Tor hidden service
setup_tor_hidden_service() {
    local service_name="$1"
    local local_port="$2"
    local tor_port="$3"
    echo "Setting up Tor hidden service for $service_name..."
    sudo apt install -y tor
    sudo bash -c "cat <<EOF >> /etc/tor/torrc
HiddenServiceDir /var/lib/tor/$service_name/
HiddenServicePort $tor_port 127.0.0.1:$local_port
EOF"
    sudo systemctl restart tor
    sleep 5
    onion_address=$(sudo cat "/var/lib/tor/$service_name/hostname")
    echo "$service_name Tor hidden service available at: $onion_address"
}

# Main script starts here
echo "Welcome to the Mempool.space deployment script for Debian."
echo "This script will deploy Mempool on your internal NAT with customizable options."
echo "You can use existing services or set up new ones locally as needed."
echo ""

# Update package lists
sudo apt update

# Prompt for Bitcoin Knots
if prompt_yes_no "Do you want to set up Bitcoin Knots locally (compiles from source)?"; then
    setup_bitcoin_knots="true"
    read -p "Enter Bitcoin RPC username: " btc_user
    read -s -p "Enter Bitcoin RPC password: " btc_pass
    echo
    btc_port=8332  # Default RPC port
else
    setup_bitcoin_knots="false"
    echo "Using existing Bitcoin node."
    read -p "Enter existing Bitcoin node RPC host: " btc_host
    read -p "Enter existing Bitcoin node RPC port (default 8332): " btc_port
    btc_port=${btc_port:-8332}
    read -p "Enter existing Bitcoin node RPC username: " btc_user
    read -s -p "Enter existing Bitcoin node RPC password: " btc_pass
    echo
fi

# Prompt for Fulcrum
if prompt_yes_no "Do you want to set up Fulcrum locally (compiles from source)?"; then
    setup_fulcrum="true"
else
    setup_fulcrum="false"
    if prompt_yes_no "Do you have an existing Elektum server for Mempool to use?"; then
        read -p "Enter existing Electrum server host: " electrum_host
        read -p "Enter existing Electrum server port (default 50002): " electrum_port
        electrum_port=${electrum_port:-50002}
    fi
fi

# Prompt for MariaDB
if prompt_yes_no "Do you want to set up MariaDB locally?"; then
    setup_mariadb="true"
else
    setup_mariadb="false"
    echo "Using existing MariaDB server."
    read -p "Enter existing MariaDB host: " db_host
    read -p "Enter existing MariaDB port (default 3306): " db_port
    db_port=${db_port:-3306}
    read -p "Enter existing MariaDB username: " db_user
    read -s -p "Enter existing MariaDB password: " db_pass
    echo
    read -p "Enter existing MariaDB database name: " db_name
fi

# Prompt for Apache2
if prompt_yes_no "Do you want to set up Apache2 locally to serve Mempool publicly?"; then
    setup_apache="true"
    read -p "Enter your domain name for Apache2 (e.g., example.com): " domain_name
    if prompt_yes_no "Do you want to set up Let's Encrypt HTTPS certificates?"; then
        setup_letsencrypt="true"
    else
        setup_letsencrypt="false"
    fi
else
    setup_apache="false"
    echo "Mempool will be served locally; configure your existing Apache2 server for public access."
fi

# Prompt for Tor hidden services
if prompt_yes_no "Do you want to set up a Tor hidden service for Mempool?"; then
    setup_tor_mempool="true"
else
    setup_tor_mempool="false"
fi

if [ "$setup_fulcrum" = "true" ] && prompt_yes_no "Do you want to set up a Tor hidden service for Fulcrum?"; then
    setup_tor_fulcrum="true"
else
    setup_tor_fulcrum="false"
fi

if [ "$setup_bitcoin_knots" = "true" ] && prompt_yes_no "Do you want to set up a Tor hidden service for Bitcoin Knots?"; then
    setup_tor_bitcoin="true"
else
    setup_tor_bitcoin="false"
fi

# Install dependencies based on choices
packages="git curl"
[ "$setup_bitcoin_knots" = "true" ] && packages="$packages build-essential libtool autotools-dev automake pkg-config bsdmainutils python3 libevent-dev libboost-system-dev libboost-filesystem-dev libboost-chrono-dev libboost-test-dev libboost-thread-dev libsqlite3-dev libminiupnpc-dev libzmq3-dev"
[ "$setup_mariadb" = "true" ] && packages="$packages mariadb-server"
[ "$setup_apache" = "true" ] && packages="$packages apache2"
[ "$setup_letsencrypt" = "true" ] && packages="$packages certbot python3-certbot-apache"
[ "$setup_tor_mempool" = "true" ] || [ "$setup_tor_fulcrum" = "true" ] || [ "$setup_tor_bitcoin" = "true" ] && packages="$packages tor"
sudo apt install -y $packages

# Install Node.js for Mempool
curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt install -y nodejs

# Set up components based on user choices
[ "$setup_bitcoin_knots" = "true" ] && setup_bitcoin_knots
[ "$setup_fulcrum" = "true" ] && setup_fulcrum
[ "$setup_mariadb" = "true" ] && setup_mariadb
setup_mempool
[ "$setup_apache" = "true" ] && setup_apache

# Set up Tor hidden services
[ "$setup_tor_mempool" = "true" ] && setup_tor_hidden_service "mempool" "4200" "80"
[ "$setup_tor_fulcrum" = "true" ] && setup_tor_hidden_service "fulcrum" "50002" "50002"
[ "$setup_tor_bitcoin" = "true" ] && setup_tor_hidden_service "bitcoin" "8333" "8333"

# Provide final instructions
echo ""
echo "Mempool deployment completed successfully!"
echo "Local access: http://$vm_ip:4200"
[ "$setup_apache" = "true" ] && echo "Public access (if configured): http${setup_letsencrypt:+s}://$domain_name"

if [ "$setup_tor_mempool" = "true" ]; then
    onion_address=$(sudo cat /var/lib/tor/mempool/hostname)
    echo "Mempool Tor hidden service: $onion_address"
fi
if [ "$setup_tor_fulcrum" = "true" ]; then
    onion_address=$(sudo cat /var/lib/tor/fulcrum/hostname)
    echo "Fulcrum Tor hidden service: $onion_address"
fi
if [ "$setup_tor_bitcoin" = "true" ]; then
    onion_address=$(sudo cat /var/lib/tor/bitcoin/hostname)
    echo "Bitcoin Knots Tor hidden service: $onion_address"
fi

if [ "$setup_apache" != "true" ]; then
    echo ""
    echo "Since you did not set up Apache2 locally, configure your existing Apache2 server with:"
    echo "<VirtualHost *:80>"
    echo "    ServerName yourdomain.com"
    echo "    ProxyPass /api http://$vm_ip:8999/"
    echo "    ProxyPassReverse /api http://$vm_ip:8999/"
    echo "    ProxyPass / http://$vm_ip:4200/"
    echo "    ProxyPassReverse / http://$vm_ip:4200/"
    echo "</VirtualHost>"
    echo "Replace 'yourdomain.com' with your domain and ensure the VM IP ($vm_ip) is correct."
    echo "For HTTPS, obtain a certificate separately on your existing server."
fi

echo "Deployment complete. Check services with 'pm2 list' and logs with 'pm2 logs'."
