# ROS Manager 
A Simple Script to Install or Uninstall any ROS2 Version.
It comes with many Smart Features, to do **one click install**.
## Usage
```
bash <(curl -sSL https://raw.githubusercontent.com/koustavbetal/ros_manager/main/rosinstaller.bash)
```
The Command Runs the Whole Script, **Recommended for New Developers**.

**For Intermediate Users**, there are some Arguments you can use:
## Options
```
-v, --version [command]         Set ROS version [humble | iron | jazzy | rolling]
-f, --force [command]           Force install type [desktop | server]
-d, --dev                       Whether to Download ros-dev-tools or not
-h, --help                      Show this help message
```
## Example
```
bash <(curl -sSL https://raw.githubusercontent.com/koustavbetal/ros_manager/main/rosinstaller.bash) -v rolling -f desktop -d
```
## Features
1. Detects the OS, Display Manager and other perferral settings before all to mitigate any mismatched version Installation.
2. Handholds the User in every step, makes it helpful for everyone.
3. Prevents multiple Parallel Installation which may lead to path conflicts.
4. Can uninstall any existing ROS version with one click.

### Flow Chart
<p align="center">
  <picture>
    <img src="Assets/flowchart.png" alt="">
  </picture>
</p>

### Disclaimer
This Script is created keeping Beginers in mind, and for Intermadiate an Professional Users this may not be the Best Solution.  
