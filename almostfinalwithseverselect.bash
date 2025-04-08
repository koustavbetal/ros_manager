#!/bin/bash

warn() { echo -e "\e[1;31m$1\e[0m"; }
# For more details about colour codes: 
# https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters


Official_install(){
    # Function to set up locale and required repositories
    echo "Setting up system environment for ROS 2..."

    # 1. Set Locale
    locale  # Check if UTF-8 is set
    sudo apt update && sudo apt install -y locales
    sudo locale-gen en_US en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export LANG=en_US.UTF-8
    locale  # Verify locale settings

    # 2. Enable required repositories
    sudo apt install -y software-properties-common
    sudo add-apt-repository universe
    sudo apt update && sudo apt install -y curl

    # 3. Add ROS 2 GPG Key and Repository
    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | \
    sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

    # 4. Update and upgrade system packages
    sudo apt update && sudo apt upgrade -y

    # 5. Install ROS 2
    sudo apt install -y "ros-$1-desktop"

    # 6. Source ROS setup file
    echo "source /opt/ros/$1/setup.bash" >> ~/.bashrc
    source ~/.bashrc

    echo "ROS 2 $1 installation completed successfully!"
}



# Function to handle fresh ROS installation
install_lobby() {
    # Suggest the best ROS version based on Ubuntu version
    if [[ "$VERSION" == "22.04" ]]; then
        RECOMMENDED_ROS="Humble Hawksbill"
        ROS_NAME="humble"
    elif [[ "$VERSION" == "24.04" ]]; then
        RECOMMENDED_ROS="Jazzy Jalisco"
        ROS_NAME="jazzy"
    else
        RECOMMENDED_ROS="No Official Recommendation for this Ubuntu Version"
        distro_picker
    fi

    echo "The host machine is running Ubuntu $VERSION."
    echo "Best Suitable for ROS 2: $RECOMMENDED_ROS."

    # Ask the user whether to install the suggested version
    read -p "Would you like to install $RECOMMENDED_ROS? (Y/n): " choice

    if [[ "$choice" =~ ^[Yy]$|^$ ]]; then
        Official_install $ROS_NAME
    else
        distro_picker
    fi
}

distro_picker(){
    # Present menu to choose another ROS 2 version
        echo "Choose a different ROS 2 distribution:"
        echo "  h) Humble Hawksbill"
        echo "  i) Iron Irwini"
        echo "  j) Jazzy Jalisco"
        echo "  r) Rolling Reidly"
        echo "  q) Quit"
        while true; do
            read -p "Enter your choice: " ROS_CHOICE
            [[ "$ROS_CHOICE" =~ ^[hijrq]$ ]] && break  # Loop until valid choice
            echo "Invalid choice! Choose wisely..."
        done

    # Map short names to full version names
    case "$ROS_CHOICE" in
        h) DISTRO="humble" ;;
        i) DISTRO="iron" ;;
        j) DISTRO="jazzy" ;;
        r) DISTRO="rolling" ;;
        q) echo "Exiting..."; exit 0 ;;
    esac
    # Print confirmation
    echo "Proceeding to Install $DISTRO..."
    Official_install $DISTRO
}


# Function to handle existing ROS installation
repair_installation() {
    echo -e "Host machine already has \e[1;34m$(echo "${INSTALLED_ROS[*]}" | tr '[:lower:]' '[:upper:]')\e[0m installed."
    read -p "Do you still want to proceed? (y/N): " proceed_choice
    [[ "$proceed_choice" =~ ^[Nn]$|^$ ]] && \
    echo -e "To Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\ " && \
    exit 0

    # Ask user whether to uninstall or do a parallel install
    echo -e "Do you wish to \e[1;34mUninstall $(echo "${INSTALLED_ROS[*]}" | tr '[:lower:]' '[:upper:]')\e[0m and Proceed with Another Version (u) \nOr Do you wish to proceed with \e[1;31m$(echo Parallel Install | tr '[:lower:]' '[:upper:]')\e[0m (p)? \n\e[1;3mQuit (q)\e[0m"

    while true; do
        read -p "Enter Your Decision (u/p/Q): " Decision

        if [[ "$Decision" =~ ^[Qq]$|^$ ]]; then
            echo -e "To Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\ " && \
            exit 1
        elif [[ "$Decision" =~ ^[Uu]$ ]]; then
            uninstall_ros "${INSTALLED_ROS[@]}"
        elif [[ "$Decision" =~ ^[Pp]$ ]]; then
            warn "Parallel Installation may Lead to Numerous Issues!"
            echo -e "\e[3mHere's the\e[0m \e]8;;https://www.reddit.com/r/ROS/comments/1iegfmz/comment/ma9avz5/\e\\statement of Open Robotics\e]8;;\e\\"
            read -p "Do You Still Want to Proceed? (y/N): " parallel_choice
            [[ "$parallel_choice" =~ ^[Nn]$|^$ ]] && echo -e "To Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\ " && \
            exit 0 || \
            echo -e "\e[3mJust for the Record... You Chose Violence!!\e[0m" 
            distro_picker
            break
        else
            echo -e "\e[3mCloudy Decision Detected. Please Verify Before Typing!\e[0m"
        fi
    done
} 


#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
echo "Checking system information..."
# Get Distro & Version (Using /etc/os-release)
[ -f /etc/os-release ] && . /etc/os-release
DISTRO="$NAME" || DISTRO="Unknown"
VERSION="$VERSION_ID" || VERSION="Unknown"
CURRENT_DESKTOP="$VERSION_CODENAME" || CURRENT_DESKTOP="Unknown"

[ "$DISTRO" != "Ubuntu" ] && echo -e "This script only works on Ubuntu! \nTo Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\ " && exit 1

# Detect installed ROS 2 versions
ROS_DIRS=(/opt/ros/*)
INSTALLED_ROS=()

for dir in "${ROS_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    INSTALLED_ROS+=("$(basename "$dir")")
done


# Call appropriate function
if [ ${#INSTALLED_ROS[@]} -gt 0 ]; then
    repair_installation
else
    install_lobby
fi