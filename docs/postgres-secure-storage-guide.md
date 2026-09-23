# PostgresSecureStorage: Linux Server Deployment Guide

This guide covers secure management of the master encryption key for `PostgresSecureStorage` on Linux servers using environment variable injection.

## Overview

`PostgresSecureStorage` encrypts xpub data using AES-256-GCM with keys derived from a master key. The master key must be:

- **32 bytes** (256 bits), base64-encoded
- Stored securely outside the application
- Injected via environment variable at runtime

## Quick Start

### 1. Generate a Master Key

```bash
# Using OpenSSL (recommended)
openssl rand -base64 32

# Or using Dart
dart run -e "import 'package:libspiffy/libspiffy.dart'; void main() async { print(await EncryptionService.generateMasterKeyBase64()); }"
```

Example output:
```
K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s=
```

### 2. Store the Key Securely

Choose one of the methods below based on your deployment.

---

## Method 1: systemd Environment File (Recommended)

Best for: Production servers running services via systemd.

### Step 1: Create a secure environment file

```bash
# Create directory with restricted permissions
sudo mkdir -p /etc/libspiffy
sudo chmod 700 /etc/libspiffy

# Create environment file
sudo tee /etc/libspiffy/secrets.env > /dev/null << 'EOF'
LIBSPIFFY_MASTER_KEY=K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s=
EOF

# Restrict permissions (root only, or specific service user)
sudo chmod 600 /etc/libspiffy/secrets.env
sudo chown root:root /etc/libspiffy/secrets.env
```

### Step 2: Configure systemd service

Create or modify `/etc/systemd/system/your-wallet-service.service`:

```ini
[Unit]
Description=Wallet Service
After=network.target postgresql.service

[Service]
Type=simple
User=wallet-service
Group=wallet-service

# Load secrets from environment file
EnvironmentFile=/etc/libspiffy/secrets.env

# Application
ExecStart=/usr/local/bin/your-wallet-service
Restart=always
RestartSec=5

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Step 3: Reload and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable your-wallet-service
sudo systemctl start your-wallet-service
```

### Verify environment is loaded

```bash
sudo systemctl show your-wallet-service --property=Environment
# Should NOT show the key (it's loaded from file)

# Check service status
sudo systemctl status your-wallet-service
```

---

## Method 2: Docker / Docker Compose

Best for: Containerized deployments.

### Option A: Docker Secrets (Swarm mode)

```bash
# Create secret
echo "K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s=" | docker secret create libspiffy_master_key -

# Use in docker-compose.yml
```

```yaml
version: '3.8'
services:
  wallet-service:
    image: your-wallet-service:latest
    secrets:
      - libspiffy_master_key
    environment:
      # Read from Docker secret file
      LIBSPIFFY_MASTER_KEY_FILE: /run/secrets/libspiffy_master_key

secrets:
  libspiffy_master_key:
    external: true
```

In your application, read from file if `_FILE` suffix is present:

```dart
String getMasterKey() {
  final keyFile = Platform.environment['LIBSPIFFY_MASTER_KEY_FILE'];
  if (keyFile != null) {
    return File(keyFile).readAsStringSync().trim();
  }
  return Platform.environment['LIBSPIFFY_MASTER_KEY']!;
}
```

### Option B: Environment file with Docker Compose

```bash
# Create .env file (NOT committed to git)
echo "LIBSPIFFY_MASTER_KEY=K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s=" > .env
chmod 600 .env
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  wallet-service:
    image: your-wallet-service:latest
    env_file:
      - .env
```

---

## Method 3: HashiCorp Vault Agent

Best for: Enterprise deployments requiring centralized secrets management.

### Step 1: Store secret in Vault

```bash
vault kv put secret/libspiffy master_key="K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s="
```

### Step 2: Configure Vault Agent template

`/etc/vault-agent/config.hcl`:

```hcl
vault {
  address = "https://vault.example.com:8200"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/etc/vault-agent/role-id"
      secret_id_file_path = "/etc/vault-agent/secret-id"
    }
  }
}

template {
  source      = "/etc/vault-agent/templates/secrets.env.ctmpl"
  destination = "/etc/libspiffy/secrets.env"
  perms       = 0600
}
```

`/etc/vault-agent/templates/secrets.env.ctmpl`:

```
{{ with secret "secret/libspiffy" }}
LIBSPIFFY_MASTER_KEY={{ .Data.data.master_key }}
{{ end }}
```

---

## Method 4: Digital Ocean App Platform

Best for: Digital Ocean deployments.

### Using DO CLI

```bash
# Set encrypted environment variable
doctl apps update <app-id> \
  --spec - << EOF
name: wallet-service
services:
- name: api
  envs:
  - key: LIBSPIFFY_MASTER_KEY
    value: "K7xZp2mN8vQ3rY6tU9wB1cD4eF5gH7jK8lM0nP2qR4s="
    type: SECRET
EOF
```

### Using App Spec YAML

```yaml
# app.yaml
name: wallet-service
services:
- name: api
  envs:
  - key: LIBSPIFFY_MASTER_KEY
    value: "ENC[your-encrypted-value]"  # Set via UI or CLI
    type: SECRET
  - key: DATABASE_URL
    value: "${db.DATABASE_URL}"
```

---

## Application Integration

### Dart/Flutter Server Application

```dart
import 'dart:io';
import 'package:libspiffy/libspiffy.dart';

Future<PostgresSecureStorage> createSecureStorage(Pool pool) async {
  // Get master key from environment
  final masterKey = Platform.environment['LIBSPIFFY_MASTER_KEY'];

  if (masterKey == null || masterKey.isEmpty) {
    throw StateError(
      'LIBSPIFFY_MASTER_KEY environment variable is not set. '
      'See docs/postgres-secure-storage-guide.md for setup instructions.',
    );
  }

  // Validate key format
  try {
    return await PostgresSecureStorage.create(
      pool: pool,
      masterKeyBase64: masterKey,
    );
  } on ArgumentError catch (e) {
    throw StateError(
      'Invalid LIBSPIFFY_MASTER_KEY: $e. '
      'Key must be 32 bytes, base64-encoded.',
    );
  }
}
```

### With Docker Secret File Support

```dart
Future<String> getMasterKey() async {
  // Check for Docker secret file first
  final keyFile = Platform.environment['LIBSPIFFY_MASTER_KEY_FILE'];
  if (keyFile != null && keyFile.isNotEmpty) {
    final file = File(keyFile);
    if (await file.exists()) {
      return (await file.readAsString()).trim();
    }
    throw StateError('Secret file not found: $keyFile');
  }

  // Fall back to direct environment variable
  final key = Platform.environment['LIBSPIFFY_MASTER_KEY'];
  if (key == null || key.isEmpty) {
    throw StateError('LIBSPIFFY_MASTER_KEY not configured');
  }
  return key;
}
```

---

## Key Rotation

When rotating the master key:

### Step 1: Add new key version

```dart
// Create storage with new key version
final newStorage = await PostgresSecureStorage.create(
  pool: pool,
  masterKeyBase64: newMasterKey,
  keyVersion: 2,  // Increment version
);
```

### Step 2: Re-encrypt existing secrets

```dart
Future<void> rotateSecrets(
  PostgresSecureStorage oldStorage,
  PostgresSecureStorage newStorage,
) async {
  // Get all wallet IDs from your read model
  final walletIds = await getXPubWalletIds();

  for (final walletId in walletIds) {
    // Read with old key
    final xpub = await oldStorage.getXPub(walletId);
    if (xpub != null) {
      // Write with new key
      await newStorage.setXPub(walletId, xpub);
    }
  }
}
```

### Step 3: Update environment and restart

```bash
# Update the secret file
sudo tee /etc/libspiffy/secrets.env > /dev/null << 'EOF'
LIBSPIFFY_MASTER_KEY=<new-key-here>
EOF

# Restart service
sudo systemctl restart your-wallet-service
```

---

## Security Best Practices

### DO

- Use file-based secrets (systemd EnvironmentFile, Docker secrets)
- Restrict file permissions to 600 (owner read/write only)
- Use separate service accounts with minimal privileges
- Rotate keys periodically
- Monitor for unauthorized access attempts
- Back up keys securely (encrypted, offline)

### DON'T

- Commit keys to version control
- Pass keys via command line arguments (visible in `ps`)
- Log keys or include in error messages
- Store keys in application config files
- Use the same key across environments (dev/staging/prod)

### Audit Checklist

```bash
# Check file permissions
ls -la /etc/libspiffy/secrets.env
# Should show: -rw------- root root

# Check no keys in process list
ps aux | grep -i libspiffy
# Should NOT show LIBSPIFFY_MASTER_KEY

# Check no keys in environment (for non-root users)
cat /proc/$(pgrep your-wallet-service)/environ | tr '\0' '\n' | grep -i key
# Should be empty or access denied
```

---

## Troubleshooting

### "LIBSPIFFY_MASTER_KEY not set"

1. Verify environment file exists and has correct permissions
2. Check systemd service loads the EnvironmentFile
3. Restart the service after changes

```bash
sudo systemctl daemon-reload
sudo systemctl restart your-wallet-service
journalctl -u your-wallet-service -f
```

### "Invalid master key: must be 32 bytes"

The key must decode to exactly 32 bytes:

```bash
# Check key length
echo -n "your-key-here" | base64 -d | wc -c
# Should output: 32
```

### "Decryption failed: authentication error"

- Key mismatch between encryption and decryption
- Data was encrypted with a different key version
- Database corruption or tampering

Check key_version in database:
```sql
SELECT key_name, key_version, created_at
FROM secure_secrets
WHERE key_name LIKE 'wallet_xpub_%';
```

---

## References

- [systemd Environment Files](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#EnvironmentFile=)
- [Docker Secrets](https://docs.docker.com/engine/swarm/secrets/)
- [HashiCorp Vault Agent](https://developer.hashicorp.com/vault/docs/agent)
- [Digital Ocean App Platform Environment Variables](https://docs.digitalocean.com/products/app-platform/how-to/use-environment-variables/)
