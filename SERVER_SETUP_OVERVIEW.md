## Server setup overview

This document describes what the `setup_server.sh` script installs and configures on a **vanilla, fully‑updated Ubuntu Server**. The script is designed to be **idempotent** (safe to re‑run).

### Execution context

- **Run as**: `root` (typically via `sudo ./setup_server.sh`).
- **Application user (`APP_USER`)**: resolved from `SUDO_USER` if present, otherwise the current user running the script.

### System packages installed (via `apt-get`)

The script runs `apt-get update` and installs:

- **curl** – for downloading resources (e.g. `nvm` installer).
- **build-essential** – compiler toolchain for building native Node.js modules and similar.
- **git** – required for pulling application code from repositories.
- **nginx** – HTTP reverse proxy / web server (no custom vhost configuration is added by this script).
- **python3-certbot-nginx** – tooling for obtaining and installing TLS certificates with Nginx (not invoked by this script).
- **ufw** – uncomplicated firewall management tool.
- **openssl** – cryptography toolkit (available for later use if needed).

### Firewall configuration

If `ufw` is available, the script:

- **Allows**: the predefined **`Nginx Full`** application profile (typically ports 80 and 443).

No other firewall rules are added or modified by this script.

### `gitdeploy` service user and SSH keys

The script ensures the presence of a dedicated deployment user:

- **User created (if missing)**: `gitdeploy`
  - **Home directory**: `/home/gitdeploy`
  - **Login shell**: `/bin/bash`
- **SSH configuration**:
  - Creates `/home/gitdeploy/.ssh` with permissions `700`, owned by `gitdeploy:gitdeploy`.
  - If not already present, generates an **Ed25519 SSH keypair** at:
    - Private key: `/home/gitdeploy/.ssh/id_ed25519`
    - Public key: `/home/gitdeploy/.ssh/id_ed25519.pub`
  - On first creation, the script prints both the **public** and **private** keys to the console so they can be captured and used for repository access.

If the user and key already exist, they are left unchanged (keys are not reprinted).

### Node.js runtime, `nvm`, and `pm2` for the application user

For the **application user (`APP_USER`)**, the script:

- **Installs `nvm`** (Node Version Manager) under `APP_USER`’s home (`$HOME/.nvm`) if not already present.
  - Version: **`v0.39.7`** of the `nvm` installer.
- **Installs Node.js LTS** (using `nvm`) if `node` is not already on the `PATH` for that user.
  - Sets the `nvm` default alias to the current LTS (`lts/*`).
- **Installs `pm2` globally** for that user (via `npm install -g pm2`) if not already available.

All of the above are configured **per‑user** (no system‑wide Node.js or `pm2` is installed).

### Shared deployment webhook service

The script provisions a **shared webhook-based deployment service** intended to support multiple applications.

- **Location**: `/opt/deploy-webhooks`
- **Owner**: recursively set to `APP_USER:APP_USER`.
- **Configuration file**: `/opt/deploy-webhooks/hooks.json`
  - Initial contents:
    - **listenHost**: `127.0.0.1` (loopback only; not exposed externally by default).
    - **listenPort**: `9000`
    - **hooks**: empty list (to be populated per application).
- **Server implementation**: `/opt/deploy-webhooks/server.js`
  - Simple Node.js HTTP server.
  - Reloads `hooks.json` on each request.
  - **Health check endpoint**: `GET /_deploy/health` (returns `{ ok: true }`).
  - For configured hooks:
    - Matches requests by path (e.g. `/my-app-hook`) from `hooks.json`.
    - Only accepts `POST` requests.
    - Requires a matching `x-webhook-secret` header for authentication.
    - On success, executes a deployment command sequence:
      - `cd` into the configured repository directory.
      - `git fetch --all --prune`
      - `git reset --hard origin/<branch>`
      - `npm ci` (or `npm install` as a fallback)
      - `pm2 restart '<pm2-process-name>'`

### Webhook service process management (`pm2` + systemd)

When `/opt/deploy-webhooks` does **not** yet exist, the script:

- Initializes a minimal Node.js project in `/opt/deploy-webhooks` using `npm init -y`.
- Starts the webhook server under `pm2` as:
  - **Process name**: `deploy-webhooks`
- Runs:
  - `pm2 save` – to persist the process list.
  - `pm2 startup systemd -u <APP_USER> --hp <APP_HOME>` – and automatically executes the generated command so that:
    - `deploy-webhooks` will **restart automatically on boot** for `APP_USER`.

If `/opt/deploy-webhooks` already exists, the script:

- **Does not** recreate configuration.
- **Restarts** the existing `deploy-webhooks` process via `pm2` and re‑saves the process list.

### Other notes and non-changes

- The script **does not**:
  - Configure specific Nginx virtual hosts or TLS certificates (beyond installing the Nginx and Certbot packages).
  - Create any database services or configure system users beyond `gitdeploy`.
  - Modify `/etc/ssh/sshd_config` or other global SSH server settings.
- At completion, the script prints a message indicating that you can now run a separate script (`02_add_app.sh`) to register specific applications and their deployment hooks.




