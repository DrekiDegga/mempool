# Mempool.space Deployment Script

This bash script deploys a Mempool.space instance on a Debian-based server, offering a flexible setup for hosting a Bitcoin blockchain explorer. It is designed to accommodate users with existing infrastructure while providing options to install and configure all necessary components from scratch. The script supports deploying Mempool.space behind an Apache2 reverse proxy, using a MariaDB database, and connecting to a Bitcoin node (either existing or a newly installed Bitcoin Knots node).

## Features
- Configurable Apache2 Setup: Uses an existing Apache2 server for reverse proxy by default, with an option to install and configure a new Apache2 server, including optional HTTPS certificates via Let's Encrypt.
- Flexible MariaDB Integration: Connects to an existing MariaDB server or installs a new local instance with a pre-configured database and user.
- Bitcoin Node Options: Connects to an existing Bitcoin node or installs Bitcoin Knots (based on the knots-installer script).
- User-Friendly Prompts: Guides the user through configuration with interactive prompts for all necessary inputs.
- Source Compilation: Uses pre-built binaries for simplicity (e.g., Bitcoin Knots), with comments indicating where source compilation can be implemented.
- Error Handling: Includes basic checks to ensure critical steps complete successfully.

## Prerequisites
- A Debian-based VM (e.g., Debian 11 or Ubuntu 20.04+).
- Root access to the VM.
- Internet access for downloading dependencies and repositories.
- For users with existing infrastructure: connection details for an Apache2 server, MariaDB server, and Bitcoin node (RPC host, port, user, password).
- Optional: A registered domain name if setting up Apache2 with Let's Encrypt HTTPS certificates.

## Installation
1. Clone this repository to your Debian VM:
   git clone https://github.com/<your-username>/<your-repo>.git
2. Navigate to the script directory:
   cd <your-repo>
3. Make the script executable:
   chmod +x deploy-mempool.sh
4. Run the script as root:
   sudo ./deploy-mempool.sh
5. Follow the interactive prompts to configure the deployment:
   - Apache2: Choose whether to use an existing server or set up a new one (with optional Let's Encrypt HTTPS).
   - MariaDB: Provide existing database details or opt to install a new local instance.
   - Bitcoin Node: Provide existing node RPC details or opt to install Bitcoin Knots.
6. Save any generated credentials (e.g., MariaDB or Bitcoin RPC passwords) displayed during setup.

## Usage
The script automates the following:
- Installs essential tools (git, curl, build-essential, Node.js).
- Clones and configures the Mempool.space repository.
- Sets up the Mempool backend and frontend.
- Configures Apache2 (if chosen) to serve the frontend and proxy API requests.
- Initializes the MariaDB database (if new) with the required schema.
- Installs and configures Bitcoin Knots (if chosen) with a txindex-enabled node.
- Creates systemd services for the Mempool backend and (if applicable) Bitcoin Knots.

After deployment:
- If using an existing Apache2 server, manually configure it to serve the frontend files (from /opt/mempool/frontend/dist) and proxy /api requests to http://localhost:8999.
- Access Mempool.space via your configured domain or server IP.
- Monitor services with:
  systemctl status mempool
  systemctl status bitcoind (if Bitcoin Knots was installed)

## Configuration
The script prompts for the following:
- Apache2: Whether to set up a new reverse proxy and optional Let's Encrypt certificates (requires a domain name).
- MariaDB: Connection details (host, database name, user, password) or permission to create a new database.
- Bitcoin Node: RPC connection details (host, port, user, password) or permission to install Bitcoin Knots.

Key configuration files:
- Mempool: /opt/mempool/backend/mempool-config.json
- Bitcoin Knots (if installed): /etc/bitcoin.conf
- Apache2 (if configured): /etc/apache2/sites-available/mempool.conf

## Customization
- Paths: Modify MEMPOOL_DIR (/opt/mempool), BACKEND_PORT (8999), or FRONTEND_DIR (/var/www/html/mempool) in the script.
- Source Compilation: Replace Bitcoin Knots binary installation with source compilation by following commented instructions in the script.
- Security: Configure a firewall (e.g., ufw) and adjust user permissions post-deployment as needed.

## Notes
- The script assumes a clean Debian environment for new installations. Ensure no conflicting services (e.g., existing Apache2 or MariaDB configurations) are running if setting up new instances.
- Bitcoin Knots installation is based on the knots-installer script (https://github.com/DrekiDegga/knots-installer), using a pre-built binary for simplicity.
- For production use, secure all credentials and consider additional hardening (e.g., firewall rules, SSL/TLS configuration).

## Contributing
Contributions are welcome! Please submit pull requests or open issues for bugs, improvements, or feature requests.

## License
This project is licensed under the MIT License. See the LICENSE file for details.

## Acknowledgments
- Mempool.space: https://github.com/mempool/mempool
- Bitcoin Knots: https://bitcoinknots.org/
- Original Bitcoin Knots installer: https://github.com/DrekiDegga/knots-installer
