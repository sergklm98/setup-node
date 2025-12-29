# This script sets up a Syncthing container to pull (sync) the creds/nodes/<node> folder from a remote device.
# It runs the container in the default Podman network and uses the Syncthing API for configuration.
#
# Steps:
# 1. Run the Syncthing container in the default Podman network with necessary volumes and ports.
# 2. Wait for Syncthing to fully initialize and retrieve the API key from the container logs or config.
# 3. Use the Syncthing REST API to add the remote device (e.g., the central node) by providing its device ID.
# 4. Use the API to add a folder for creds/nodes/<node>, setting the path and linking it to the remote device for pulling.
# 5. Start the folder sync and monitor the process until completion or errors.
# 6. When done, optionally stop and remove the Syncthing container.
# 7. Optionally reuse generated credentials for deploying syncthing app in the dualstack network later.
