# System Patterns: Setup Node

## Architecture Overview

The system follows a distributed, containerized architecture with centralized configuration management:

```
[Local Workstation] <---SSH---> [VPS Node]
        |                           |
        | (Syncthing)               | (Podman)
        v                           v
[Configuration Sync] <---------> [Container Runtime]
                                    |
                                    v
                            [Overlay Networks]
```

## Core Patterns

### 1. Infrastructure as Code
- All infrastructure defined through version-controlled scripts
- Configuration templates for different node types
- Declarative network and service definitions

### 2. Container-First Design
- All applications run in Podman containers
- Rootless containers for enhanced security
- Quadlet files for systemd integration
- Volume mounts for persistent data

### 3. Distributed Configuration
- Syncthing for peer-to-peer configuration sync
- Node-specific configuration folders
- Automatic conflict resolution
- Real-time synchronization

### 4. Overlay Network Mesh
- Multiple network protocols for redundancy
- Automatic peer discovery
- Dynamic routing configuration
- Network segmentation support

### 5. Secure by Default
- SSH key-based authentication
- Minimal attack surface
- Firewall rules for network isolation
- Encrypted communication channels

## Design Patterns

### Configuration Management
- **Template Pattern**: Reusable configuration templates
- **Inheritance Pattern**: Base configs with node-specific overrides
- **Synchronization Pattern**: Distributed state management

### Deployment Patterns
- **Blue-Green Deployment**: Rolling updates with fallback
- **Immutable Infrastructure**: Container-based deployments
- **Canary Releases**: Gradual rollout of changes

### Network Patterns
- **Mesh Networking**: Full connectivity between nodes
- **Service Discovery**: Automatic service location
- **Load Balancing**: Traffic distribution across nodes

## Implementation Patterns

### Script Organization
- Modular scripts in `infra/` directory
- Error handling with rollback capabilities
- Logging for debugging and monitoring

### Container Patterns
- Single responsibility per container
- Health checks for service monitoring
- Resource limits and constraints

### Security Patterns
- Principle of least privilege
- Defense in depth approach
- Regular security updates