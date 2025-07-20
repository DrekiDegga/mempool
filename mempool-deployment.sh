#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Update package lists and install essential tools
echo "Updating package lists and installing essential tools..."
apt update
apt install -y git curl build-essential wget openssl || {
  echo "Failed to install essential tools"
  exit 1
}

# Install Node.js if not present
if ! command -v node &> /dev/null; then
  echo "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
  apt install -y nodejs || {
    echo "Failed to install Node.js"
    exit 1
  }
fi

# Define variables
MEMPOOL_DIR="/opt/mempool"
BACKEND_PORT=8999
FRONTEND_DIR="/var/www/html/mempool"

# Create mempool user for running the service
echo "Creating mempool system user..."
adduser --system --group --no-create-home mempool || {
  echo "Failed to create mempool user"
  exit 1
}

# Prompt for Apache2 setup
echo -e "\nDo you want to set up a new Apache2 reverse proxy? (yes/no)"
echo "If 'no', the script assumes an existing Apache2 server will be configured manually."
read -p "Choice: " setup_apache
if [ "$setup_apache" = "yes" ]; then
  echo "Enter the domain name for Mempool.space (e.g., mempool.example.com):"
  read -p "Domain: " domain
  echo "Do you want to obtain HTTPS certificates from Let's Encrypt? (yes/no)"
  read -p "Choice: " setup_cert
fi

# Prompt for MariaDB setup
echo -e "\nDo you want to use an existing MariaDB server? (yes/no)"
echo "If 'yes', provide connection details; if 'no', a new local MariaDB will be set up."
read -p "Choice: " use_existing_db
if [ "$use_existing_db" = "no" ]; then
  db_host="localhost"
  db_name="mempool"
  db_user="mempool_user"
  db_pass=$(openssl rand -base64 12)
  echo "Generated MariaDB password: $db_pass (save this securely)"
else
  echo "Enter database host:"
  read -p "Host: " db_host
  echo "Enter database name:"
  read -p "Name: " db_name
  echo "Enter database user:"
  read -p "User: " db_user
  echo "Enter database password:"
  read -p "Password: " db_pass
fi

# Prompt for Bitcoin node setup
echo -e "\nDo you want to use an existing Bitcoin node? (yes/no)"
echo "If 'yes', provide RPC details; if 'no', Bitcoin Knots will be installed."
read -p "Choice: " use_existing_node
if [ "$use_existing_node" = "no" ]; then
  rpc_host="localhost"
  rpc_port=8332
  rpc_user="bitcoinrpc"
  rpc_pass=$(openssl rand -base64 12)
  echo "Generated Bitcoin RPC password: $rpc_pass (save this securely)"
else
  echo "Enter Bitcoin node RPC host:"
  read -p "Host: " rpc_host
  echo "Enter Bitcoin node RPC port:"
  read -p "Port: " rpc_port
  echo "Enter Bitcoin node RPC user:"
  read -p "User: " rpc_user
  echo "Enter Bitcoin node RPC password:"
  read -p "Password: " rpc_pass
fi

# Set up new MariaDB if chosen
if [ "$use_existing_db" = "no" ]; then
  echo "Installing and configuring MariaDB..."
  apt install -y mariadb-server || {
    echo "Failed to install MariaDB"
    exit 1
  }
  mysql_secure_installation
  mysql -e "CREATE DATABASE $db_name;" || {
    echo "Failed to create database"
    exit 1
  }
  mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';" || {
    echo "Failed to create database user"
    exit 1
  }
  mysql -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';" || {
    echo "Failed to grant privileges"
    exit 1
  }
  mysql -e "FLUSH PRIVILEGES;"
fi

# Set up Bitcoin Knots if chosen
if [ "$use_existing_node" = "no" ]; then
  echo "Installing Bitcoin Knots..."
  # Using pre-built binary as in your knots-installer; source compilation can be added here
  KNOTS_VERSION="25.0.knots20220531"
  wget https://bitcoinknots.org/files/25.x/$KNOTS_VERSION/bitcoin-$KNOTS_VERSION-x86_64-linux-gnu.tar.gz || {
    echo "Failed to download Bitcoin Knots"
    exit 1
  }
  tar -xvf bitcoin-$KNOTS_VERSION-x86_64-linux-gnu.tar.gz || {
    echo "Failed to extract Bitcoin Knots"
    exit 1
  }
  mv bitcoin-$KNOTS_VERSION/bin/* /usr/local/bin/ || {
    echo "Failed to install Bitcoin Knots binaries"
    exit 1
  }
  rm -rf bitcoin-$KNOTS_VERSION*
  adduser --system --group --no-create-home bitcoin || {
    echo "Failed to create bitcoin user"
    exit 1
  }
  mkdir -p /var/lib/bitcoind
  chown bitcoin:bitcoin /var/lib/bitcoind
  cat > /etc/bitcoin.conf << EOL
rpcuser=$rpc_user
rpcpassword=$rpc_pass
rpcport=$rpc_port
server=1
txindex=1
EOL
  chown bitcoin:bitcoin /etc/bitcoin.conf
  chmod 600 /etc/bitcoin.conf
  cat > /etc/systemd/system/bitcoind.service << EOL
[Unit]
Description=Bitcoin daemon
After=network.target
[Service]
ExecStart=/usr/local/bin/bitcoind -daemon -conf=/etc/bitcoin.conf -datadir=/var/lib/bitcoind
User=bitcoin
Type=forking
Restart=always
TimeoutSec=120
RestartSec=30
[Install]
WantedBy=multi-user.target
EOL
  systemctl enable bitcoind || {
    echo "Failed to enable bitcoind service"
    exit 1
  }
  systemctl start bitcoind || {
    echo "Failed to start bitcoind service"
    exit 1
  }
  # Note: To compile from source, replace the above with git clone, dependencies, and make
fi

# Deploy Mempool.space
echo "Cloning Mempool.space repository..."
git clone https://github.com/mempool/mempool.git "$MEMPOOL_DIR" || {
  echo "Failed to clone Mempool repository"
  exit 1
}
chown -R mempool:mempool "$MEMPOOL_DIR"

# Set up Mempool backend
echo "Setting up Mempool backend..."
cd "$MEMPOOL_DIR/backend"
sudo -u mempool npm install || {
  echo "Failed to install backend dependencies"
  exit 1
}
# Check if build is needed; assuming npm install prepares dist/index.js
if [ -f "package.json" ] && grep -q '"build"' package.json; then
  sudo -u mempool npm run build || {
    echo "Failed to build backend"
    exit 1
  }
fi

# Configure mempool-config.json
echo "Configuring Mempool backend..."
sed -i "s/\"BITCOIN_NODE_HOST\": \".*\"/\"BITCOIN_NODE_HOST\": \"$rpc_host\"/" mempool-config.json || {
  echo "Failed to configure Bitcoin node host"
  exit 1
}
sed -i "s/\"BITCOIN_NODE_PORT\": .*/\"BITCOIN_NODE_PORT\": $rpc_port/" mempool-config.json || {
  echo "Failed to configure Bitcoin node port"
  exit 1
}
sed -i "s/\"BITCOIN_NODE_USER\": \".*\"/\"BITCOIN_NODE_USER\": \"$rpc_user\"/" mempool-config.json || {
  echo "Failed to configure Bitcoin node user"
  exit 1
}
sed -i "s/\"BITCOIN_NODE_PASS\": \".*\"/\"BITCOIN_NODE_PASS\": \"$rpc_pass\"/" mempool-config.json || {
  echo "Failed to configure Bitcoin node password"
  exit 1
}
sed -i "s/\"MYSQL_HOST\": \".*\"/\"MYSQL_HOST\": \"$db_host\"/" mempool-config.json || {
  echo "Failed to configure MySQL host"
  exit 1
}
sed -i "s/\"MYSQL_DATABASE\": \".*\"/\"MYSQL_DATABASE\": \"$db_name\"/" mempool-config.json || {
  echo "Failed to configure MySQL database"
  exit 1
}
sed -i "s/\"MYSQL_USER\": \".*\"/\"MYSQL_USER\": \"$db_user\"/" mempool-config.json || {
  echo "Failed to configure MySQL user"
  exit 1
}
sed -i "s/\"MYSQL_PASSWORD\": \".*\"/\"MYSQL_PASSWORD\": \"$db_pass\"/" mempool-config.json || {
  echo "Failed to configure MySQL password"
  exit 1
}

# Initialize database schema if new database
if [ "$use_existing_db" = "no" ]; then
  echo "Initializing Mempool database schema..."
  mysql -u "$db_user" -p"$db_pass" "$db_name" < "$MEMPOOL_DIR/mariadb-structure.sql" || {
    echo "Failed to initialize database schema"
    exit 1
  }
fi

# Set up systemd service for Mempool backend
echo "Setting up Mempool backend service..."
cat > /etc/systemd/system/mempool.service << EOL
[Unit]
Description=Mempool Backend
After=network.target
[Service]
User=mempool
WorkingDirectory=$MEMPOOL_DIR/backend
ExecStart=/usr/bin/node --max-old-space-size=2048 dist/index.js
Restart=always
[Install]
WantedBy=multi-user.target
EOL
systemctl enable mempool || {
  echo "Failed to enable mempool service"
  exit 1
}
systemctl start mempool || {
  echo "Failed to start mempool service"
  exit 1
}

# Set up Mempool frontend
echo "Setting up Mempool frontend..."
cd "$MEMPOOL_DIR/frontend"
sudo -u mempool npm install || {
  echo "Failed to install frontend dependencies"
  exit 1
}
sudo -u mempool npm run build || {
  echo "Failed to build frontend"
  exit 1
}

# Configure Apache2 if chosen
if [ "$setup_apache" = "yes" ]; then
  echo "Configuring Apache2 reverse proxy..."
  mkdir -p "$FRONTEND_DIR"
  cp -r dist/* "$FRONTEND_DIR" || {
    echo "Failed to copy frontend files"
    exit 1
  }
  apt install -y apache2 || {
    echo "Failed to install Apache2"
    exit 1
  }
  a2enmod proxy proxy_http rewrite || {
    echo "Failed to enable Apache2 modules"
    exit 1
  }
  cat > /etc/apache2/sites-available/mempool.conf << EOL
<VirtualHost *:80>
    ServerName $domain
    DocumentRoot $FRONTEND_DIR
    <Directory $FRONTEND_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ProxyPass /api http://localhost:$BACKEND_PORT
    ProxyPassReverse /api http://localhost:$BACKEND_PORT
</VirtualHost>
EOL
  a2ensite mempool || {
    echo "Failed to enable Apache2 site"
    exit 1
  }
  systemctl reload apache2 || {
    echo "Failed to reload Apache2"
    exit 1
  }
  if [ "$setup_cert" = "yes" ]; then
    echo "Setting up Let's Encrypt certificates..."
    apt install -y certbot python3-certbot-apache || {
      echo "Failed to install Certbot"
      exit 1
    }
    certbot --apache -d "$domain" || {
      echo "Failed to obtain Let's Encrypt certificate"
      exit 1
    }
  fi
else
  echo -e "\nMempool frontend built at $MEMPOOL_DIR/frontend/dist"
  echo "Please configure your existing Apache2 server to:"
  echo "1. Serve the static files from $MEMPOOL_DIR/frontend/dist"
  echo "2. Proxy /api requests to http://localhost:$BACKEND_PORT"
fi

echo -e "\nDeployment complete!"
echo "Mempool.space backend is running on port $BACKEND_PORT"
if [ "$use_existing_db" = "no" ]; then
  echo "MariaDB credentials: User: $db_user, Password: $db_pass, Database: $db_name"
fi
if [ "$use_existing_node" = "no" ]; then
  echo "Bitcoin Knots RPC credentials: User: $rpc_user, Password: $rpc_pass, Port: $rpc_port"
fi
