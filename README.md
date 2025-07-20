# Mempool.space Deployment Script

This Bash script deploys an instance of [Mempool.space](https://mempool.space) on an internal VM, serving it via Apache over HTTP. It integrates with your existing MariaDB server, Electrum server, and Bitcoin node, and optionally sets up a TOR hidden service. The script also provides configuration instructions to serve Mempool.space publicly via an existing Apache2 server over HTTPS.

## Features

- Deploys Mempool.space on an internal VM using Apache over HTTP.
- Integrates with existing MariaDB, Electrum, and Bitcoin services.
- Installs the latest stable LTS version of Node.js from NodeSource.
- Creates a systemd service for the Mempool backend.
- Optionally sets up a TOR hidden service.
- Generates a random password for local MariaDB deployments.
- Provides a detailed summary with access points, service details, and troubleshooting tips.

## Prerequisites

- **Operating System**: Debian-based system (e.g., Ubuntu).
- **Existing Services**:
  - Bitcoin node (RPC enabled).
  - Electrum server.
  - MariaDB server (if not using a local database).
- **Network**: The internal VM’s IP must be accessible from the public Apache2 server for reverse proxying.
- **Permissions**: Run the script with `sudo` on the internal VM.

## Usage

1. **Clone the Repository**:
   Clone this repository to your internal VM using:
   git clone https://github.com/yourusername/your-repo-name.git
   Then navigate to the directory:
   cd your-repo-name

2. **Run the Script**:
   Execute the script with sudo:
   sudo ./deploy-mempool.sh

3. **Follow the Prompts**:
   - The script will ask for database, Bitcoin RPC, and Electrum server details.
   - Press Enter to accept default values where applicable.
   - If using a local database, a random password will be generated and displayed.

4. **Public Access Configuration**:
   - The script provides a configuration snippet for your existing Apache2 server to reverse proxy the internal deployment over HTTPS.
   - Adjust the `ServerName` and SSL certificate paths in the snippet to match your setup.

5. **TOR Hidden Service (Optional)**:
   - If enabled, the script sets up a TOR hidden service and provides the onion address in the summary.

## Configuration Details

- **Database**:
  - For local deployments, a MariaDB database is created with a generated password.
  - For remote databases, ensure the MariaDB server allows connections from the VM’s IP.

- **Bitcoin RPC**:
  - Connects to your existing Bitcoin node using the provided RPC credentials.

- **Electrum Server**:
  - Integrates with your existing Electrum server for transaction data.

- **Node.js**:
  - Installs the latest stable LTS version from NodeSource to ensure compatibility.

- **Systemd Service**:
  - Creates `mempool.service` to manage the backend, running as the `mempool` user.

## Summary and Troubleshooting

After deployment, the script provides a summary including:

- **Access Points**: Internal URL and TOR onion address (if enabled).
- **Service Details**: Installed services and their statuses.
- **Database Information**: Host, port, database name, user, and password (if generated).
- **Public Access Instructions**: Configuration for your existing Apache2 server.
- **Update Recommendations**: Steps to update Mempool.space using `git pull`.
- **Troubleshooting Tips**: Commands to check service statuses and view logs.

### Example Troubleshooting Commands

- Check service statuses:
  systemctl status mempool
  systemctl status apache2
  systemctl status tor  (if TOR is enabled)
  systemctl status mariadb  (if using a local database)

- View recent logs:
  journalctl -u mempool -n 20
  journalctl -u apache2 -n 20
  journalctl -u tor -n 20  (if TOR is enabled)
  journalctl -u mariadb -n 20  (if using a local database)

## Notes

- Ensure your Bitcoin node, Electrum server, and MariaDB server (if remote) are running and configured to accept connections from the VM.
- For remote MariaDB deployments, verify that the database user has the necessary privileges.
- Adjust the public Apache2 configuration (`ServerName`, SSL paths) to match your environment.

---

This script simplifies the deployment of Mempool.space on an internal VM while leveraging your existing infrastructure. It ensures a secure and efficient setup with minimal user intervention.
