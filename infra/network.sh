# This script creates a dualstack Podman network (supporting both IPv4 and IPv6).
#
# Steps:
# 1. Check if Podman is installed and running.
# 2. Define the network configuration (name, subnet for IPv4 and IPv6, gateway, etc.).
# 3. Create the Podman network using 'podman network create' with dualstack options.
# 4. Verify the network creation and list available networks.