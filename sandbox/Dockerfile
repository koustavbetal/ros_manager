# A throwaway "fresh Ubuntu" for testing ros-manager without touching the host.
# Mirrors a stock install: a sudo user, whiptail and wget (all priority "important"); no curl, no ROS.
ARG UBUNTU=24.04
FROM ubuntu:${UBUNTU}

RUN apt-get update \
 && apt-get install -y --no-install-recommends sudo whiptail wget ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash robot \
 && echo 'robot ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/robot

USER robot
WORKDIR /home/robot
ENV TERM=xterm-256color
