#!/bin/bash
# Run ros-manager inside a throwaway Ubuntu container.
#
#   ./sandbox/run.bash                          # Ubuntu 24.04, interactive TUI
#   ./sandbox/run.bash 22.04                    # Ubuntu 22.04 (humble)
#   ./sandbox/run.bash 24.04 -v jazzy -w gazebo,nav2 -y
#
# When the installer finishes you land in a shell inside the container to check the result
# (e.g. `ros2 run demo_nodes_cpp talker`). Exiting that shell deletes the container.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
UBUNTU=24.04
[[ $1 =~ ^[0-9]{2}\.[0-9]{2}$ ]] && { UBUNTU=$1; shift; }
IMAGE="rosman-sandbox:$UBUNTU"

docker build -q --build-arg UBUNTU="$UBUNTU" -t "$IMAGE" "$HERE" >/dev/null
docker run --rm -it --name "rosman-$UBUNTU" -e COLORTERM \
    -v "$HERE/..:/ros-manager:ro" \
    "$IMAGE" bash -c 'bash /ros-manager/ros-manager.bash "$@"; exec bash' _ "$@"
