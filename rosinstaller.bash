#!/bin/bash

: '
Koustav Betal ROS(2) Installer/Uninstaller
@license    MIT
@author     "Koustav Betal" <Koustavbetal.official@gmail.com>
@version    0.5.2
@link       <>
'
# =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-= =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-==-=-=--=-=-=-=-=-|

function warn() { echo -e "\e[1;31m$1\e[0m"; }
function passed() { echo -e "\e[1;32m$1\e[0m";}
function heading() { 
    echo -e "\n$(printf '=%.0s' {1..60})"
    echo -e "\e[1;34m$1\e[0m"
    echo -e "$(printf '=%.0s' {1..60})"
}
# For more details about colour codes: 
# https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_(Select_Graphic_Rendition)_parameters

function feedback_callback() { 
    echo -e "\n$(printf '=%.0s' {1..22}) = - = O = - = $(printf '=%.0s' {1..23})"
    echo -e "Thank You \e[1;32m$(whoami | tr '[:lower:]' '[:upper:]')\e[0m for Using this Script.\nTo Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\"
    echo -e "$(printf '=%.0s' {1..23}) = - = O = - = $(printf '=%.0s' {1..23})\n"
}

function decorator(){
    TERM_WIDTH=$(tput cols) # Get terminal width
    ICON="[@_@]" # Create a simple ASCII icon that works in any terminal
    local ORIGINAL_MSG="$1"  # Keep the original message with escape sequences
    
    # Remove ANSI escape sequences from input for length calculation only
    local CLEAN_MSG=$(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g; s/\x1B\]8;;[^[]+\x1B\\//g; s/\x1B\]8;;\x1B\\//g')
    
    local TOTAL_LENGTH=$(( ${#ICON} + 1 + ${#CLEAN_MSG} )) # Calculate spaces based on clean message
    
    # Rest of your centering code remains the same
    local OUTER_WIDTH=$(( TOTAL_LENGTH * 300 / 100 ))
    if (( OUTER_WIDTH > TERM_WIDTH )); then
        OUTER_WIDTH=$TERM_WIDTH
    fi
    SEPARATOR=$(printf '%*s' "$OUTER_WIDTH" | tr ' ' '=')
    
    local INNER_WIDTH=$(( TOTAL_LENGTH * 200 / 100 ))
    if (( INNER_WIDTH > TERM_WIDTH )); then
        INNER_WIDTH=$TERM_WIDTH
    fi
    INNER_SEPARATOR=$(printf '%*s' "$INNER_WIDTH" | tr ' ' '*')
    
    local OUTER_PADDING=$(( (TERM_WIDTH - OUTER_WIDTH) / 2 ))
    local INNER_PADDING=$(( (TERM_WIDTH - INNER_WIDTH) / 2 ))
    local TEXT_PADDING=$(( (OUTER_WIDTH - TOTAL_LENGTH) / 2 ))
    
    # Print with the original message that contains escape sequences
    printf "%*s%s\n" $OUTER_PADDING "" "$SEPARATOR"
    printf "%*s%s\n" $INNER_PADDING "" "$INNER_SEPARATOR"
    printf "%*s%s %b\n" $(( OUTER_PADDING + TEXT_PADDING )) "" "$ICON" "$ORIGINAL_MSG"
    printf "%*s%s\n" $INNER_PADDING "" "$INNER_SEPARATOR"
    printf "%*s%s\n" $OUTER_PADDING "" "$SEPARATOR"
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Functional Programs-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#  

function parse_args() {
    while [[ "$#" -gt 0 ]]; do
        arged="true"
        PARSED_VERSION="Initialising Choosing Procedure..."
        FORCED="Not Specified! Choosing Based on the System."
        case "$1" in
            -v|--version)
            VERSION_VALID=false
            for distro in "${VALID_ROS_DISTROS[@]}"; do
                if [[ "$2" == "$distro" ]]; then
                    PARSED_VERSION="$2"
                    VERSION_VALID=true
                    break
                fi
            done

            if [[ "$VERSION_VALID" == true ]]; then
                shift 2
            else
                echo -e "\e[1;31mInvalid ROS version: $2\e[0m"
                echo "Accepted values: ${VALID_ROS_DISTROS[*]}"
                exit 1
            fi
            ;;

            -f|--force)
                if [[ "$2" =~ ^(desktop|server)$ ]]; then
                    FORCED="$2"
                    shift 2
                else
                    warn "Invalid install type: $2"
                    echo -e "\e[3mAccepted values: desktop or server \n[Use: -h for more Info.]\e[0m" 
                    exit 1
                fi
                ;;
            -d|--dev)
                DEV_TOOLS=true
                shift
                ;;
            -h|--help)
                echo -e "Usage: $0 [OPTIONS]\n"
                echo "Options:"
                echo "  -v, --version [command]         Set ROS version (${VALID_ROS_DISTROS[*]})"
                echo "  -f, --force [command]           Force install type [desktop | server]"
                echo "  -d, --dev                       whether to Download ros-dev-tools or not"
                echo "  -h, --help                      Show this help message"
                exit 0
                ;;
            *)
                echo -e "\e[1;31mUnknown option: $1\e[0m"
                exit 1
                ;;
        esac
        
    done
    if [[ "$arged" == "true" ]]; then 
        heading "User Request Accepted !!"
        echo -e "\e[1mDistro:\e[0m \e[3;36m$PARSED_VERSION\e[0m"
        echo -e "\e[1mType:\e[0m \e[3;36m$FORCED\e[0m"
        echo -e "\e[1mDev Tools:\e[0m \e[3;36m$DEV_TOOLS\e[0m"
        # echo -e "$(printf '=%.0s' {1..60})\n"
        if [[ "$PARSED_VERSION" != "Initialising Choosing Procedure..." ]];then
            Official_install $PARSED_VERSION
        else
            Sys_Info
        fi
    else
        Sys_Info
    fi
}

function Sys_Info(){
    heading "Verifying System Information !!"

    [ -f /etc/os-release ] && . /etc/os-release
    DISTRO="$NAME" || DISTRO="Unknown"
    VERSION="$VERSION_ID" || VERSION="Unknown"
    CURRENT_DESKTOP="$VERSION_CODENAME" || CURRENT_DESKTOP="Unknown"

    # TERMINATING THE FLOW IF NOT UBUNTU !
    [ "$DISTRO" != "Ubuntu" ] && \
    warn "This script only works on Ubuntu! \nTo Report an Issue or Sugessions Find me \e]8;;https://x.com/koustavbetal\e\\@koustav_betal\e]8;;\e\\ " && exit 1

    # Detect installed ROS 2 versions
    ROS_DIRS=(/opt/ros/*)
    INSTALLED_ROS=()

    for dir in "${ROS_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        INSTALLED_ROS+=("$(basename "$dir")")
    done

    # Check for ubuntu-desktop or ubuntu-server packages with version info
    if dpkg -l ubuntu-desktop 2>/dev/null | grep -q "^ii"; then
        # Get the package details
        PACKAGE_INFO=$(dpkg -l ubuntu-desktop | grep "^ii")
        PACKAGE_NAME=$(echo "$PACKAGE_INFO" | awk '{print $2}')
        PACKAGE_VERSION=$(echo "$PACKAGE_INFO" | awk '{print $3}')
        HOST_OS_INFO="\e[3;36m$PACKAGE_NAME | version:$PACKAGE_VERSION\e[0m"
        IS_SERVER=false
        # echo -e "$HOST_OS_INFO"
        
    elif dpkg -l ubuntu-server 2>/dev/null | grep -q "^ii"; then
        # Get the package details
        PACKAGE_INFO=$(dpkg -l ubuntu-server | grep "^ii")
        PACKAGE_NAME=$(echo "$PACKAGE_INFO" | awk '{print $2}')
        PACKAGE_VERSION=$(echo "$PACKAGE_INFO" | awk '{print $3}')
        HOST_OS_INFO="\e[3;36m$PACKAGE_NAME | version:$PACKAGE_VERSION\e[0m"
        IS_SERVER=true
    else
        echo "Could not determine system type through packages"
        read -p "Do you Want to Install ROS Server Edition [ros-base] (y/N): " SERVER_DESICION
        if [[ "$SERVER_DESICION" =~ ^[Nn]$|^$ ]]; then
            IS_SERVER=false
        elif [[ "$SERVER_DESICION" =~ ^[Yy]$ ]]; then
            IS_SERVER=true
        fi
    fi

    # Call appropriate function
    if [ ${#INSTALLED_ROS[@]} -gt 0 ]; then
        repair_installation
    else
        install_lobby
    fi
}

function distro_picker(){
    # Present menu to choose another ROS 2 version
        echo -e "\n\e[1mChoose a different ROS 2 distribution:\e[0m"
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
        q) feedback_callback; exit 0 ;;
    esac
    # Print confirmation
    echo "Proceeding to Install $DISTRO..."
    Official_install $DISTRO
}

function  uninstall_ros(){
    echo "uninstalling $1"

    sudo apt remove ~nros-$1-* && sudo apt autoremove
    sudo rm /etc/apt/sources.list.d/ros2.list
    sudo apt update
    sudo apt autoremove
    # Consider upgrading for packages previously shadowed.
    sudo apt upgrade
    echo -e "\n$(printf '=%.0s' {1..60})"
    install_lobby
}

function Official_install(){
    echo -e "\n$(printf '=%.0s' {1..60})\n"
    if [[ "$IS_SERVER" = "true" && "$FORCED" = "desktop" ]]; then
        warn "This is not a Viable Choice.\nYou Should Not Install Desktop Version on a Server Build."
        echo "Redirecting to install $1-server..."
        echo -e "\e[1mInstalling ROS 2:\e[0m \e[1;3;36m$1-server\e[0m"
        INSCRIPT=sudo apt install -y ros-$1-ros-base
    elif [[ "$IS_SERVER" = "true" ]]; then
        echo -e "\e[1mInstalling ROS 2:\e[0m \e[1;3;36m$1-server\e[0m"
        INSCRIPT="sudo apt install -y ros-$1-ros-base"
    elif [[ "$IS_SERVER" = "false" && "$FORCED" = "server" ]]; then
        echo -e "\e[1mInstalling ROS 2:\e[0m \e[1;3;36m$1-server\e[0m"
        INSCRIPT="sudo apt install -y ros-$1-ros-base"
    else
        echo -e "\e[1mInstalling ROS 2:\e[0m \e[1;3;36m$1-desktop\e[0m"
        INSCRIPT="sudo apt install -y ros-$1-desktop"
    fi
        
    echo " " # Print initial 3 lines for countdown (just placeholders)
    echo " "
    echo " "

    for i in {3..1}; do
        tput cuu 2 # Move cursor up 2 lines
        tput el # Clears next lines
        echo -e "\e[1;3;31mThe Installation will begin in ... $i\e[0m"
        tput el
        echo -e "\e[3;36m^C to cancel\e[0m"
        sleep 1
    done
    tput cuu 2
    tput el
    echo -e "\n\e[1;3;36mHere We Go ...\e[0m\n"

    # 1. Set Locale
    locale  # Check if UTF-8 is set
    sudo apt update && sudo apt install -y locales
    sudo locale-gen en_US en_US.UTF-8
    sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export LANG=en_US.UTF-8
    locale  # Verify locale settings

    # 2. Enable required repositories
    sudo apt install -y software-properties-common
    sudo add-apt-repository universe -y
    sudo apt update && sudo apt install -y curl

    # 3. Add ROS 2 GPG Key and Repository
    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | \
    sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null

    # 4. Update and upgrade system packages
    sudo apt update && sudo apt upgrade -y

    # # 5. Install ROS 2
    $INSCRIPT

    # 5.5 Install Dev Tools
    if [[ "$DEV_TOOLS" = "true" ]]; then
        sudo apt install ros-dev-tools
    fi
    wrap_up $1
}

function wrap_up(){
    passed "ROS 2: $1 installation completed successfully!"

    read -p "Do You Want ROS to be Initiated at Startup?? (Y/n): " env_var
    if [[ "$env_var" =~ ^[Yy]$|^$ ]]; then
        echo "source /opt/ros/$1/setup.bash" >> ~/.bashrc
        source ~/.bashrc        
    fi
    feedback_callback
    echo -e "\e[3mType "ros2" to verify the Installation.\nIf 'command not found', Re-Open the Terminal Window."
}

function install_lobby() {
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

    echo -e "The host machine is running \e[1;36mUbuntu $VERSION\e[0m. \e[3m[$HOST_OS_INFO]\e[0m"
    echo -e "Best Suitable for ROS 2: \e[1;32m$RECOMMENDED_ROS.\e[0m"

    # Ask the user whether to install the suggested version
    read -p "Would you like to install $RECOMMENDED_ROS? (Y/n): " choice

    if [[ "$choice" =~ ^[Yy]$|^$ ]]; then
        Official_install $ROS_NAME
    else
        distro_picker
    fi
}

function repair_installation() {
    echo -e "Host machine already has \e[1;34m$(echo "${INSTALLED_ROS[*]}" | tr '[:lower:]' '[:upper:]')\e[0m installed."
    read -p "Do you still want to proceed? (y/N): " proceed_choice
    [[ "$proceed_choice" =~ ^[Nn]$|^$ ]] && \
    feedback_callback && exit 0

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
            [[ "$parallel_choice" =~ ^[Nn]$|^$ ]] && feedback_callback && \
            exit 0 || \
            echo -e "\e[3mJust for the Record... You Chose Violence!!\e[0m" 
            distro_picker
            break
        else
            echo -e "\e[3mCloudy Decision Detected. Please Verify Before Typing!\e[0m"
        fi
    done
} 

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- main function -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
: '
In main we are checking:
1. system information to flow without any error and automating processes.
2. Determining the flow of the script acccording to the system.
'
#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#  
IS_SERVER="false"
FORCED=""
DEV_TOOLS="false"
VALID_ROS_DISTROS=("humble" "iron" "jazzy" "rolling") # List of valid ROS distros

sudo -v
clear
decorator "ROS Installer/Uninstaller Script by \e]8;;https://github.com/koustavbetal/ros_manager\e\\@Koustav Betal\e]8;;\e\\"
parse_args "$@"
