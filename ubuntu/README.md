# Ubuntu SSH Container - Access Guide

This container runs Ubuntu 26.04 (Resolute) with OpenSSH server pre-installed.

## Container Details

- **Base Image**: ubuntu:26.04
- **SSH Port**: 22 (internal)
- **Network**: net-boundary-private (internal)
- **Container Name**: zero_trust_boundary_ssh

## User Credentials

### Boundary User (recommended)
- **Username**: `boundary`
- **Password**: `password`
- **Privileges**: sudo access (passwordless)

### Root User
- **Username**: `root`
- **Password**: `password`

## How to SSH Into the Container

### Option 1: From Another Container on the Same Network

SSH from any container on the `net-boundary-private` network:

```bash
ssh boundary@zero_trust_boundary_ssh
# Password: password
```

### Option 2: Using Podman Exec (Direct Shell Access)

Get a shell directly without SSH:

```bash
# As boundary user
podman exec -it zero_trust_boundary_ssh su - boundary

# As root
podman exec -it zero_trust_boundary_ssh bash
```

### Option 3: Expose SSH Port to Host (Add to docker-compose.yml)

If you want to SSH from your host machine, add port mapping to the service:

```yaml
boundary-ssh:
  build:
    context: ./ubuntu
    dockerfile: Dockerfile
  container_name: zero_trust_boundary_ssh
  profiles: [access-control]
  ports:
    - "2222:22"  # Add this line
  networks:
    - net-boundary-private
```

Then SSH from your host:

```bash
ssh -p 2222 boundary@localhost
# Password: password
```

### Option 4: Through HashiCorp Boundary (Workshop Purpose)

This container is designed to be accessed through HashiCorp Boundary for the workshop:

1. Configure Boundary target pointing to `zero_trust_boundary_ssh:22`
2. Use Boundary to establish SSH session
3. Boundary will broker the connection securely

## Testing SSH Service

Check if SSH is running:

```bash
podman exec zero_trust_boundary_ssh systemctl status ssh
```

Or:

```bash
podman exec zero_trust_boundary_ssh ps aux | grep sshd
```

## Troubleshooting

### SSH Connection Refused

Check if the container is running:
```bash
podman ps | grep boundary_ssh
```

Check SSH daemon:
```bash
podman exec zero_trust_boundary_ssh /usr/sbin/sshd -T
```

### View SSH Logs

```bash
podman logs zero_trust_boundary_ssh
```

### Restart SSH Service

```bash
podman exec zero_trust_boundary_ssh /usr/sbin/sshd -D
```

## Security Notes

- Default passwords are intentionally simple for workshop purposes
- In production, use SSH keys instead of passwords
- The container is on an internal network for security
- Access should be brokered through Boundary in the workshop scenario