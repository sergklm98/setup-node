# This script installs apps chosen to be deployed to the node.
#
# Steps:
# 1. Read a configuration file or environment variables to determine which apps to install (e.g., wireguard, nebula, dns, syncthing, code-server).
# 2. For each selected app, navigate to the corresponding folder in 'apps/'.
# 3. Run the build script to build the container image if needed.
# 4. Run the deploy script to deploy the container using Podman/Quadlet.
# 5. Ensure the containers are started and integrated with the dualstack network.
# 6. Log the installation process and any errors.