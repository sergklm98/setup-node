# Project Brief: Setup Node

## Core Requirements

This project provides automation scripts for setting up and managing VPS nodes in an overlay network infrastructure. The system enables rapid deployment of secure, interconnected nodes using containerized applications.

## Goals

1. **Automated Node Provisioning**: Streamline VPS setup with minimal manual intervention
2. **Container-Based Architecture**: All applications run in Podman containers for isolation and portability
3. **Mesh Network Connectivity**: Nodes interconnect through multiple VPN and overlay networks (WireGuard, Nebula, Yggdrasil, I2Pd)
4. **Configuration Synchronization**: Use Syncthing for distributed configuration management across nodes
5. **Infrastructure as Code**: Maintain infrastructure state through version-controlled scripts and configurations

## Key Features

- **Multi-Network Support**: Support for WireGuard, Nebula, Yggdrasil, and I2Pd overlay networks
- **Application Ecosystem**: Pre-configured containers for DNS, Syncthing, and other services
- **SSH-Based Deployment**: Secure remote execution using key-based authentication
- **Configuration Templates**: Reusable templates for different node types and applications
- **State Synchronization**: Distributed configuration management via Syncthing

## Success Criteria

- Deploy a new node in under 30 minutes
- Zero manual configuration on target VPS
- Automatic service discovery and interconnection
- Reliable configuration synchronization
- Secure by default with proper firewall rules