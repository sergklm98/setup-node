# This bootstrap script orchestrates the setup of a new VPS node for the overlay network by executing three key scripts in sequence:
# 1. infra/podman.sh - Identifies the Debian version and installs the latest Podman with Quadlet support.
# 2. infra/pull-configs.sh - Pulls the latest configuration files for the node via syncthing.
# 3. infra/network.sh - Creates a dualstack Podman network (supporting both IPv4 and IPv6).
# 4. infra/apps.sh - Installs the selected applications chosen to be deployed on the node.
# Before running each script, it performs checks to ensure all required configuration parameters are properly set, preventing failures and ensuring a smooth deployment process.
