# Docker sandbox

Test `ros-manager.bash` on a fresh Ubuntu without touching your machine.
The image is plain Ubuntu plus a sudo user (`robot`), `wget` and `whiptail`: what a stock install ships with. No curl, no ROS.

Run every command from `ros-manager_v2/`.

## Which Ubuntu for which distro

| ROS 2 distro | Ubuntu | Image tag |
|---|---|---|
| humble | 22.04 jammy | `rosman-sandbox:22.04` |
| jazzy | 24.04 noble | `rosman-sandbox:24.04` |
| kilted | 24.04 noble | `rosman-sandbox:24.04` |
| lyrical | 26.04 resolute | `rosman-sandbox:26.04` |
| rolling | 26.04 resolute | `rosman-sandbox:26.04` |

The script reads this mapping live from rosdistro. If a distro moves to a new Ubuntu release, the installer's splash screen (the "Available" line) shows it first.

## Quick way: one command

```bash
./sandbox/run.bash 22.04                    # humble
./sandbox/run.bash 24.04                    # jazzy / kilted
./sandbox/run.bash 26.04                    # lyrical / rolling
./sandbox/run.bash 24.04 -v kilted -t base -w nav2 -y   # any installer flags after the version
```

It builds the image if needed, runs the installer, then leaves you in a shell inside the container. `exit` deletes the container.

## Step by step

### 1. Build the image (once per Ubuntu version)

```bash
docker build -t rosman-sandbox:22.04 --build-arg UBUNTU=22.04 sandbox   # humble
docker build -t rosman-sandbox:24.04 --build-arg UBUNTU=24.04 sandbox   # jazzy, kilted
docker build -t rosman-sandbox:26.04 --build-arg UBUNTU=26.04 sandbox   # lyrical, rolling
```

### 2. Start a container

Throwaway (deleted on `exit`):

```bash
docker run --rm -it -e COLORTERM -v "$PWD":/ros-manager:ro rosman-sandbox:24.04
```

Kept (resume later with `docker start -ai rosman-jazzy`):

```bash
docker run -it --name rosman-jazzy -e COLORTERM -v "$PWD":/ros-manager:ro rosman-sandbox:24.04
```

Swap the tag and name for other distros, e.g. `rosman-sandbox:22.04` / `rosman-humble`.

### 3. Run the installer (inside the container)

```bash
bash /ros-manager/ros-manager.bash                 # interactive
bash /ros-manager/ros-manager.bash -n              # dry run
bash /ros-manager/ros-manager.bash -v jazzy -t base -y
```

The repo is mounted read-only, so edits on your machine show up immediately. Rerun the command without restarting the container.

### 4. Check the result (inside the container)

```bash
source /opt/ros/jazzy/setup.bash
ros2 run demo_nodes_cpp talker            # Ctrl+C to stop
ls ~/.local/state/ros-manager/            # install logs
```

## Clean up / start over

```bash
docker rm -f rosman-jazzy                 # a kept container (any name you used)
docker ps -a --filter name=rosman         # list leftovers
docker rmi rosman-sandbox:24.04           # the image; next build starts from scratch
docker rmi rosman-sandbox:22.04 rosman-sandbox:24.04 rosman-sandbox:26.04   # all of them
docker builder prune -f                   # build cache too
```

## Limits

- Docker counts as a server: there is no `ubuntu-desktop` package, so the default is `ros-base`. Pick `desktop` in the menu to test the full install.
- GUI tools (RViz, Gazebo) can't open from the container without X11/Wayland forwarding.
- For a check closer to bare metal, use a VM: `sudo snap install multipass && multipass launch 24.04`.
