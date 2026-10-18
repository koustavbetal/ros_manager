#!/bin/bash
# SPDX-License-Identifier: MIT

: '
ROS Manager v2: ROS 2 installer. The TUI covers download and install only.
@license    MIT (see LICENSE)
@copyright  2025-2026 Koustav Betal
@author     "Koustav Betal" <https://lnjstudios.com>
@version    2.1.0-dev
@link       <https://github.com/koustavbetal/ros_manager>

ROS is a trademark of Open Robotics. This project is independent and not affiliated with Open Robotics.

Uses only what ships with Ubuntu: bash, apt, tput, coreutils. Prompts are drawn inline, no dialog tools.
curl is installed by the script itself, the same way the official ROS docs do it.

Usage
    bash <(wget -qO- lnjstudios.com/ros-man) [options]     # or: bash ros-manager.bash [options]
    bash ros-manager.bash --help                           # every option
    source ros-manager.bash                                # functions only; main runs only when executed

Sections (search for "#-=-=-")
    Configuration · Footer (install screen) · Runners · Install steps · Flow · Splash
    Inline prompts · Plugin browser · main

Every function has a doc block right above it:
    # name <args>: what it does
    #   in:  arguments, and the globals it reads
    #   out: what it prints (stdout), the globals it sets, its return status
'

set -o pipefail

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Configuration -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
RM_VERSION="2.1.0-dev"
ROSDISTRO_URL="https://raw.githubusercontent.com/ros/rosdistro/master"
# Only used when rosdistro can't be reached: distro -> Ubuntu codename(s)
declare -A FALLBACK_UBUNTU=([humble]=jammy [jazzy]=noble [kilted]=noble [lyrical]=resolute [rolling]=resolute)
# Only used when the ROS docs / distro-info can't be read (offline, slow network, minimal images): names never change
declare -A FALLBACK_NAME=([ardent]="Ardent Apalone" [bouncy]="Bouncy Bolson" [crystal]="Crystal Clemmys" [dashing]="Dashing Diademata"
    [eloquent]="Eloquent Elusor" [foxy]="Foxy Fitzroy" [galactic]="Galactic Geochelone" [humble]="Humble Hawksbill" [iron]="Iron Irwini"
    [jazzy]="Jazzy Jalisco" [kilted]="Kilted Kaiju" [lyrical]="Lyrical Luth" [rolling]="Rolling Ridley")
declare -A FALLBACK_UBUNTU_NAME=([bionic]="18.04 LTS|Bionic Beaver" [focal]="20.04 LTS|Focal Fossa" [jammy]="22.04 LTS|Jammy Jellyfish"
    [noble]="24.04 LTS|Noble Numbat" [resolute]="26.04 LTS|Resolute Raccoon")
declare -A DISTRO_UBUNTU=() DISTRO_STATUS=()
# Full names and dates come from the official ROS 2 docs; without them, FALLBACK_NAME
RELEASES_URL="https://raw.githubusercontent.com/ros2/ros2_documentation/rolling/source/Releases.rst"
declare -A DISTRO_NAME=() DISTRO_REL=() DISTRO_EOL=()
VALID_DISTROS=() RECOMMENDED="" ROSDISTRO_LIVE=0   # filled by discover_distros for this machine's Ubuntu

# id | chip name | description | packages  ("@" becomes the distro)
MODULES=(
    "gazebo|Gazebo|Gazebo simulator + ros_gz bridge|ros-@-ros-gz"
    "moveit|MoveIt|MoveIt 2 motion planning|ros-@-moveit"
    "nav2|Nav2|Nav2 navigation stack|ros-@-navigation2 ros-@-nav2-bringup"
    "slam|SLAM|SLAM Toolbox mapping|ros-@-slam-toolbox"
    "urdf|URDF|URDF tools: xacro, joint_state_publisher_gui|ros-@-xacro ros-@-joint-state-publisher-gui ros-@-robot-state-publisher"
    "control|Control|ros2_control + ros2_controllers|ros-@-ros2-control ros-@-ros2-controllers"
    "teleop|Teleop|Joystick + teleop (joy, teleop_twist_*)|ros-@-joy ros-@-teleop-twist-joy ros-@-teleop-twist-keyboard"
    "devtools|DevTools|colcon, rosdep, vcstool (ros-dev-tools)|ros-dev-tools"
)

DISTRO="" ROS_TYPE="" WITH="" REMOVE=""
MODE="" TARGET="" INSTALLED=()   # MODE: fresh | extras | parallel | replace | remove; TARGET: the installed distro acted on
PREREQS=(locales software-properties-common curl ca-certificates)
ASSUME_YES=0 DRY_RUN=0 DO_UPGRADE=1 ADD_BASHRC=1 ORIG_ARGS=()
# ROS 2 ships setup.bash and setup.zsh (no fish etc.): the login shell picks which one, and which rc file gets it
LOGIN_SHELL="" RC_SHELL=bash RC_FILE="$HOME/.bashrc" RC_ADDED=0
SUDO=""; (( EUID != 0 )) && SUDO="sudo"

. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ros-manager"
LOGFILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

# Palette: restyle everything from here
C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m'
C_DONE=$'\e[38;5;78m' C_CUR=$'\e[38;5;208m' C_TODO=$'\e[38;5;245m' C_SEP=$'\e[38;5;237m' C_ERR=$'\e[38;5;203m'
C_WARN=$'\e[38;5;220m'   # C_CUR is the accent (cursor, prompts, labels); C_WARN marks "usable, but not here"
RAMP_RGB=(220 50 47  245 135 30  240 200 40  90 200 90)   # bar gradient stops: red → orange → yellow → green
RAMP_256=(196 202 208 214 220 226 190 154 118 82)          # same ramp for terminals without truecolor


#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Footer (2-layer progress) -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# Install screen: answers on top, pane A (steps) | pane B (live log, "l"), pinned footer at the bottom:
#   ──────────────────────────────────────────────────── ↑↓ scroll  l log ──
#    ✓ Prepare  ✓ Sources  ● ROS 2  ○ Gazebo  ○ Nav2       ██████░░░░  40%
#    ⠋ Installing ros-jazzy-desktop · Retrieving file 12 of 480 ███░░░░░░░  25%
# Both bars are flush with the right edge and use the same red → green gradient.
STAGES=() STAGE_DESC=() STEPS=()
STAGE_IDX=0 TASK_PCT=0 TASK_LABEL="" UI_ACTIVE=0 FOOTER_H=3 BAR_W=30 RAMP=()
# While the install runs, one process (the ticker) does all the drawing, from files in UI_DIR. Two writers would
# interleave mid-sequence and share the terminal's single \e7 slot: stray colours, a screen that scrolls.
#   steps   pane A: say lines, and "\x01<stage idx>" for a stage heading    stage   current stage [+ " failed"]
#   footer  the two footer rows (ui_draw)    cmd  the running command (pane B's top line)    log_on  pane B shown
#   scroll  pane A's first line while scrolled back (none: follow the end)    dirty   redraw pane A now (a key)
UI_DIR="" MID_TOP=1 KEY_PID="" SPIN_PID=""
PKG_LOG="" RUN_START=""   # PKG_LOG: "<stage idx> R|N|U <package>" (requested / new / upgraded) for the summary

# ui_init: start the live install screen under the answers (hidden cursor, no key echo, mouse wheel on, key listener + ticker)
#   in:  none; needs a terminal of 15+ rows, else the install prints plain text
#   out: UI_ACTIVE=1, UI_DIR, ROWS, COLS, MID_TOP
ui_init() {
    local need avail
    [[ -t 1 ]] || return 0
    ROWS=$(tput lines); COLS=$(tput cols)
    (( ROWS > 14 )) || return 0
    UI_DIR=$(mktemp -d); : >"$UI_DIR/steps"
    MID_TOP=$(cursor_row); MID_TOP=${MID_TOP:-$ROWS}
    need=$(( 8 + FOOTER_H )) avail=$(( ROWS - MID_TOP + 1 ))
    if (( avail < need )); then   # not enough room under the answers: scroll the splash up a bit
        printf '\e[%d;1H' "$ROWS"; printf '\n%.0s' $(seq 1 $(( need - avail )))
        MID_TOP=$(( ROWS - need + 1 ))
    fi
    printf '\e[%d;1H\e[J' "$MID_TOP"
    tput civis
    [[ -t 0 ]] && { stty -echo; printf '\e[?1000h\e[?1006h'; }   # the mouse wheel scrolls pane A
    UI_ACTIVE=1
    trap ui_resize WINCH
    ui_layout
    ui_draw
    key_listener_start
    spinner_start
}

# ui_layout: size the progress bars to the terminal and precompute their gradient, one colour per cell
#   in:  COLS, COLORTERM (truecolor uses RAMP_RGB, else RAMP_256)
#   out: BAR_W, RAMP
ui_layout() {
    local i n=$(( ${#RAMP_RGB[@]} / 3 - 1 )) f seg a b r g bl
    BAR_W=$(( COLS / 4 )); (( BAR_W > 30 )) && BAR_W=30; (( BAR_W < 5 )) && BAR_W=5
    RAMP=()
    for (( i = 0; i < BAR_W; i++ )); do
        if [[ $COLORTERM == truecolor || $COLORTERM == 24bit ]]; then
            f=$(( i * n * 1000 / (BAR_W - 1) ))            # position along the stops, x1000
            seg=$(( f / 1000 )); (( seg >= n )) && seg=$(( n - 1 ))
            f=$(( f - seg * 1000 )); a=$(( seg * 3 )); b=$(( a + 3 ))
            r=$((  RAMP_RGB[a]     + (RAMP_RGB[b]     - RAMP_RGB[a])     * f / 1000 ))
            g=$((  RAMP_RGB[a + 1] + (RAMP_RGB[b + 1] - RAMP_RGB[a + 1]) * f / 1000 ))
            bl=$(( RAMP_RGB[a + 2] + (RAMP_RGB[b + 2] - RAMP_RGB[a + 2]) * f / 1000 ))
            RAMP+=($'\e[38;2;'"$r;$g;${bl}m")
        else
            RAMP+=($'\e[38;5;'"${RAMP_256[i * ${#RAMP_256[@]} / BAR_W]}m")
        fi
    done
}

# ui_end [clear]: stop the live screen and hand the terminal back
#   in:  $1 "clear" wipes the panes (for the summary); otherwise pane A's step list is drawn once more and left on screen
#   out: UI_ACTIVE=0, UI_DIR removed, cursor / key echo / mouse restored
ui_end() {
    (( UI_ACTIVE )) || return 0
    UI_ACTIVE=0
    key_listener_stop
    spinner_stop
    [[ -t 0 ]] && printf '\e[?1000l\e[?1006l'
    if [[ $1 == clear ]]; then
        printf '\e[%d;1H\e[J' "$MID_TOP"
    else
        rm -f "$UI_DIR/log_on" "$UI_DIR/scroll"; render_mid; printf '%s' "$MID"
        printf '\e[%d;1H\e[J' $(( ROWS - FOOTER_H + 1 ))
    fi
    [[ -t 0 ]] && stty echo
    tput cnorm
    rm -rf "$UI_DIR"
}

# ui_resize: SIGWINCH handler: re-measure the terminal and redraw
#   in:  none
#   out: ROWS, COLS, BAR_W; restarts the key listener and the ticker (both hold the old size)
ui_resize() {
    (( UI_ACTIVE )) || return 0
    key_listener_stop; spinner_stop   # both hold the old size
    ROWS=$(tput lines); COLS=$(tput cols)
    printf '\e[%d;1H\e[J' "$MID_TOP"
    ui_layout
    ui_draw
    key_listener_start
    spinner_start
}

# bar <pct>: one gradient progress bar
#   in:  $1 percent (clamped to 0-100), BAR_W, RAMP
#   out: stdout: BAR_W cells + " NNN%" (BAR_W + 5 columns)
bar() {
    local pct=$1 filled i out=""
    (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
    filled=$(( pct * BAR_W / 100 ))
    for (( i = 0; i < BAR_W; i++ )); do
        if (( i < filled )); then out+="${RAMP[i]}█"; else out+="${C_SEP}░"; fi
    done
    printf '%s %s%3d%%%s' "$out" "${RAMP[filled > 0 ? filled - 1 : 0]}" "$pct" "$C_RESET"
}

# footer_line <row> <left text> <left width> <bar>: one footer row, bar flush right
#   in:  $1 screen row, $2 text (may hold colours), $3 its visible width, $4 output of bar
#   out: appends to FOOTER (ends one column short of the edge, so the terminal never wraps)
footer_line() {
    local pad=$(( COLS - 1 - $3 - BAR_W - 5 )) line
    (( pad < 1 )) && pad=1
    printf -v line '\e[%d;1H\e[0m\e[2K%s%*s%s' "$1" "$2" "$pad" "" "$4"
    FOOTER+=$line
}

# footer_rule [scrolled]: the rule above the footer, with the key hints
#   in:  $1 non-empty while pane A is scrolled back (adds "End back to live")
#   out: RULE
footer_rule() {
    local LC_ALL=C.UTF-8 keys plain w rule
    keys="${C_CUR}↑↓${C_SEP} scroll  ${C_CUR}l${C_SEP} log" plain="↑↓ scroll  l log"
    [[ -n $1 ]] && keys="${C_WARN}End${C_SEP} back to live  $keys" plain="End back to live  $plain"
    w=$(( COLS - ${#plain} - 5 )); (( w < 0 )) && w=0
    printf -v rule '%*s' "$w" ''
    printf -v RULE '\e[%d;1H\e[0m\e[2K%s%s %s %s──%s' $(( ROWS - 2 )) "$C_SEP" "${rule// /─}" "$keys" "$C_SEP" "$C_RESET"
}

SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
# spin_frame: the spinner glyph for this moment (changes every 0.1 s)
#   in:  none (the clock)
#   out: stdout: one character of SPIN_FRAMES
spin_frame() { local t=${EPOCHREALTIME/[.,]/}; printf '%s' "${SPIN_FRAMES[t / 100000 % ${#SPIN_FRAMES[@]}]}"; }

# spinner_start: start the ticker, the only process that writes to the terminal while the install screen is up
#   in:  files in UI_DIR; every 0.1 s the spinner, every 0.2 s (or right after a key) the panes,
#        the footer whenever $UI_DIR/footer or the scroll state changed
#   out: SPIN_PID
spinner_start() {
    spinner_stop
    ( trap exit TERM
      n=0 last=""
      while kill -0 $$ 2>/dev/null; do
          out=""
          if (( n++ % 2 == 0 )) || [[ -e $UI_DIR/dirty ]]; then rm -f "$UI_DIR/dirty"; render_mid; out=$MID; fi
          foot=$(<"$UI_DIR/footer") scrolled=""
          [[ -s $UI_DIR/scroll ]] && scrolled=1
          if [[ -n $foot && $foot$scrolled != "$last" ]]; then last=$foot$scrolled; footer_rule "$scrolled"; out+=$RULE$foot; fi
          printf '%s\e[%d;2H%s%s%s' "$out" "$ROWS" "$C_CUR" "$(spin_frame)" "$C_RESET"
          sleep 0.1
      done ) 2>/dev/null &
    SPIN_PID=$!
}

# spinner_stop: stop the ticker
#   in:  SPIN_PID
#   out: SPIN_PID=""
spinner_stop() { [[ -n $SPIN_PID ]] && { kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=""; }; }

# cursor_row: ask the terminal which row the cursor is on (\e[6n)
#   in:  none; needs a terminal on stdin and waits up to 1 s for the reply
#   out: stdout: the row number, nothing if the terminal didn't answer
cursor_row() {
    local r c
    [[ -t 0 ]] || return 0   # (stdout is a pipe here: we're always called as $(cursor_row))
    IFS='[;' read -rsd R -t 1 -p $'\e[6n' _ r c </dev/tty 2>/dev/tty && printf '%s' "$r"
}

# scroll_by <lines>: move pane A's view
#   in:  $1 lines, negative = up; $UI_DIR/steps, ROWS, FOOTER_H, MID_TOP
#   out: $UI_DIR/scroll = the new first line; removed (follow live) once the view reaches the end
scroll_by() {
    local n h top max
    n=$(wc -l <"$UI_DIR/steps") h=$(( ROWS - FOOTER_H - MID_TOP ))
    max=$(( n > h ? n - h : 0 )) top=$max
    [[ -s $UI_DIR/scroll ]] && read -r top <"$UI_DIR/scroll"
    top=$(( top + $1 )); (( top < 0 )) && top=0
    if (( top >= max )); then rm -f "$UI_DIR/scroll"; else echo "$top" >"$UI_DIR/scroll"; fi
}

# key_listener_start: background reader for the install screen's keys
#   in:  ↑↓ / j k, PgUp PgDn / space, Home End / g G, mouse wheel (scroll pane A); l (toggle pane B)
#   out: KEY_PID; state files in UI_DIR, plus $UI_DIR/dirty so the ticker redraws at once
key_listener_start() {
    key_listener_stop
    [[ -t 0 ]] || return 0
    ( trap exit TERM
      exec 3</dev/tty
      page=$(( ROWS - FOOTER_H - MID_TOP - 1 ))
      while IFS= read -rsn1 -u 3 k; do
          if [[ $k == $'\e' ]]; then   # "\e[A", "\e[5~", SGR mouse "\e[<64;12;5M"
              IFS= read -rsn1 -t 0.05 -u 3 c; k+=$c
              if [[ $c == '[' ]]; then
                  IFS= read -rsn1 -t 0.05 -u 3 c; k+=$c
                  while [[ $c == [0-9\;\<] ]] && IFS= read -rsn1 -t 0.05 -u 3 c; do k+=$c; done
              fi
          fi
          case $k in
              [lL])                if [[ -e $UI_DIR/log_on ]]; then rm -f "$UI_DIR/log_on"; else : >"$UI_DIR/log_on"; fi ;;
              $'\e[A'|k)           scroll_by -1 ;;
              $'\e[B'|j)           scroll_by 1 ;;
              $'\e[<64;'*M)        scroll_by -3 ;;
              $'\e[<65;'*M)        scroll_by 3 ;;
              $'\e[5~')            scroll_by -"$page" ;;
              $'\e[6~'|' ')        scroll_by "$page" ;;
              $'\e[H'|$'\e[1~'|g)  scroll_by -1000000 ;;
              $'\e[F'|$'\e[4~'|G)  rm -f "$UI_DIR/scroll" ;;
              *)                   continue ;;
          esac
          : >"$UI_DIR/dirty"
      done ) 2>/dev/null &
    KEY_PID=$!
}

# key_listener_stop: stop the key reader
#   in:  KEY_PID
#   out: KEY_PID=""
key_listener_stop() { [[ -n $KEY_PID ]] && { kill "$KEY_PID" 2>/dev/null; wait "$KEY_PID" 2>/dev/null; KEY_PID=""; }; }

# fitv <text> <width>: cut text to a width with an ellipsis, keeping its colours (no subshell)
#   in:  $1 text (may hold colour codes), $2 width in columns
#   out: FIT
fitv() {
    local LC_ALL=C.UTF-8 plain rest out="" seg left re=$'^([^\e]*)(\e\\[[0-9;]*m)(.*)$'
    shopt -s extglob
    plain=${1//$'\e['*([0-9;])m/}
    if (( ${#plain} <= $2 )); then FIT=$1; return; fi
    left=$(( $2 > 1 ? $2 - 1 : 0 )) rest=$1
    while (( left > 0 )) && [[ $rest =~ $re ]]; do   # walk text/escape pairs, counting only the text
        seg=${BASH_REMATCH[1]}
        if (( ${#seg} >= left )); then out+=${seg:0:left}; left=0; break; fi
        out+=$seg${BASH_REMATCH[2]}; (( left -= ${#seg} )); rest=${BASH_REMATCH[3]}
    done
    (( left > 0 )) && out+=${rest:0:left}
    FIT="$out…$C_RESET"
}

# head_line <stage idx> <current stage> <failed> <width>: a stage heading for pane A
#   in:  $1 stage to draw, $2 stage running now, $3 non-empty if that one failed, $4 width; STAGES
#   out: HEAD: "✓ Name ────" green when done, spinner/orange running, ✗ red failed, ○ grey not started
head_line() {
    local LC_ALL=C.UTF-8 name=${STAGES[$1]} icon col w rule
    if   (( $1 < $2 )); then icon="✓" col=$C_DONE
    elif (( $1 > $2 )); then icon="○" col=$C_TODO
    elif [[ -n $3 ]];   then icon="✗" col=$C_ERR
    elif (( UI_ACTIVE )); then icon=$(spin_frame) col=$C_CUR
    else icon="●" col=$C_CUR; fi
    w=$(( $4 - ${#name} - 3 )); (( w < 0 )) && w=0
    printf -v rule '%*s' "$w" ''
    HEAD="${col}${icon} ${C_BOLD}${name}${C_RESET} ${C_SEP}${rule// /─}${C_RESET}"
}

# Pane A is a list with sticky stage headings: a heading scrolled past waits at the top edge, one still
# below waits at the bottom edge, stacked in order; everything else slides between them.
# render_mid: compose one frame of the middle area (pane A, and pane B when "l" is on)
#   in:  UI_DIR files (steps, stage, scroll, log_on, cmd), LOGFILE, ROWS, COLS, MID_TOP
#   out: MID: escape sequences for every row, written by the caller in one go
render_mid() {
    local LC_ALL=C.UTF-8 h lw=$COLS rw=0 i j k p n top max line cmd="" stage=0 failed="" lines=() row=() heads=() logs=()
    MID=""
    [[ -n $UI_DIR && -d $UI_DIR ]] || return 0
    h=$(( ROWS - FOOTER_H - MID_TOP ))
    (( h > 0 )) || return 0
    if [[ -e $UI_DIR/log_on ]]; then lw=$(( COLS * 2 / 5 )); rw=$(( COLS - lw - 3 )); fi
    read -r stage failed <"$UI_DIR/stage" 2>/dev/null
    mapfile -t lines <"$UI_DIR/steps"
    n=${#lines[@]} max=$(( n > h ? n - h : 0 )) top=$max
    [[ -s $UI_DIR/scroll ]] && read -r top <"$UI_DIR/scroll"
    (( top > max )) && top=$max
    for (( i = 0; i < h; i++ )); do row[i]=$(( top + i < n ? top + i : -1 )); done
    for i in "${!lines[@]}"; do [[ ${lines[i]} == $'\x01'* ]] && heads+=("$i"); done
    if (( ${#heads[@]} * 2 < h )); then   # (too many to stack on a short screen: plain scrolling)
        for j in "${!heads[@]}"; do
            p=$(( heads[j] - top ))
            (( p < j )) && p=$j
            (( p > h - ${#heads[@]} + j )) && p=$(( h - ${#heads[@]} + j ))
            row[p]=${heads[j]}
        done
    fi
    (( rw > 0 )) && mapfile -t logs < <(tail -n $(( h - 1 )) "$LOGFILE" 2>/dev/null)
    [[ -s $UI_DIR/cmd ]] && read -r cmd <"$UI_DIR/cmd"
    for (( i = 0; i < h; i++ )); do
        k=${row[i]} FIT=""
        if (( k >= 0 )); then
            if [[ ${lines[k]} == $'\x01'* ]]; then   # (on the top row it runs into pane B's header)
                head_line "${lines[k]#?}" "$stage" "$failed" $(( i == 0 && rw > 0 ? lw : lw - 1 )); FIT=$HEAD
            else fitv "${lines[k]}" $(( lw - 1 )); fi
        fi
        printf -v line '\e[%d;1H\e[0m\e[2K%s%s' $(( MID_TOP + i )) "$FIT" "$C_RESET"; MID+=$line
        (( rw > 0 )) || continue
        if (( i == 0 )); then   # header: the top heading's rule runs on through ─ $ running command ───; │ starts below it
            line=${cmd:+\$ $cmd}; k=$(( COLS - lw - 7 ))
            fitv "$line" "$k"; (( ${#line} < k )) && k=${#line}
            if (( k )); then printf -v line '%*s' $(( COLS - lw - 5 - k )) ''; FIT="─ $C_CUR$FIT$C_RESET$C_SEP ${line// /─}"
            else printf -v line '%*s' $(( COLS - lw - 2 )) ''; FIT=${line// /─}; fi   # (nothing running yet)
            printf -v line '\e[%d;%dH%s─%s%s' $(( MID_TOP + i )) $(( lw + 1 )) "$C_SEP" "$FIT" "$C_RESET"
            MID+=$line; continue
        else
            line=${logs[i - 1]//[$'\t\r']/ }; line=${line//$'\e'/}
            fitv "$line" "$rw"; k=$C_DIM
        fi
        printf -v line '\e[%d;%dH%s│%s %s%s%s' $(( MID_TOP + i )) $(( lw + 1 )) "$C_SEP" "$C_RESET" "$k" "$FIT" "$C_RESET"
        MID+=$line
    done
}

# ui_draw: footer state for the ticker (stage chips + overall bar, task label + task bar)
#   in:  STAGES, STAGE_IDX, TASK_PCT, TASK_LABEL; does nothing while the screen is off
#   out: $UI_DIR/footer, $UI_DIR/stage
ui_draw() {
    (( UI_ACTIVE )) || return 0
    local LC_ALL=C.UTF-8   # so ${#str} counts characters, not bytes, even before the locale is set up
    local n=${#STAGES[@]} chips="" plain=0 i pct label
    (( n )) || n=1
    pct=$(( (STAGE_IDX * 100 + TASK_PCT) / n )); (( pct > 100 )) && pct=100

    for i in "${!STAGES[@]}"; do
        if   (( i < STAGE_IDX ));  then chips+="${C_DONE}✓ ${STAGES[i]}${C_RESET}  "
        elif (( i == STAGE_IDX )); then chips+="${C_CUR}${C_BOLD}● ${STAGES[i]}${C_RESET}  "
        else                            chips+="${C_TODO}○ ${STAGES[i]}${C_RESET}  "; fi
        plain=$(( plain + ${#STAGES[i]} + 4 ))
    done
    if (( plain + BAR_W + 10 > COLS )); then   # narrow terminal: compact stage line
        label="Stage $(( STAGE_IDX < n ? STAGE_IDX + 1 : n ))/$n · ${STAGES[STAGE_IDX]:-Done}"
        chips="${C_CUR}${C_BOLD}${label}${C_RESET}"; plain=${#label}
    fi
    label=${TASK_LABEL:0:$(( COLS - BAR_W - 11 ))}

    FOOTER=""
    footer_line $((ROWS - 1)) " $chips" $(( plain + 1 )) "$(bar "$pct")"
    footer_line "$ROWS" " ${C_CUR}$(spin_frame)${C_RESET} ${C_DIM}${label}${C_RESET}" $(( ${#label} + 3 )) "$(bar "$TASK_PCT")"
    printf '%s' "$FOOTER" >"$UI_DIR/footer"
    printf '%s\n' "$STAGE_IDX" >"$UI_DIR/stage"
}

# task <pct> <label>: update the task line of the footer
#   in:  $1 percent, $2 label
#   out: TASK_PCT, TASK_LABEL; footer redrawn
task()  { TASK_PCT=$1; TASK_LABEL=$2; ui_draw; }
# say <text...>: one line of what we did (echo -e: colour codes work)
#   in:  the text
#   out: a line in pane A, or stdout when the screen is off
say()   { if (( UI_ACTIVE )); then echo -e "  $*" >>"$UI_DIR/steps"; else echo -e "  $*"; fi; }
# say_head <stage idx>: a stage heading in pane A, drawn live (spinner, then ✓ or ✗)
#   in:  $1 stage index into STAGES
#   out: a heading marker in $UI_DIR/steps, or the heading on stdout when the screen is off
say_head() {
    if (( UI_ACTIVE )); then printf '\x01%s\n' "$1" >>"$UI_DIR/steps"
    else head_line "$1" "$1" "" 60; echo -e "\n$HEAD"; fi
}
# ok <text...>: say with a green ✓
#   in:  the text
#   out: see say
ok()    { say "${C_DONE}✓${C_RESET} $*"; }
# warn <text...>: say with a red !
#   in:  the text
#   out: see say
warn()  { say "${C_ERR}!${C_RESET} $*"; }

# die <message>: stop with an error and the tail of the log
#   in:  $1 message; STAGE_IDX (marked ✗ when the screen is up), LOGFILE
#   out: never returns: exit 1
die() {
    (( UI_ACTIVE )) && printf '%s failed\n' "$STAGE_IDX" >"$UI_DIR/stage"
    ui_end
    echo -e "\n${C_ERR}${C_BOLD}✗ $1${C_RESET}"
    if [[ -s $LOGFILE ]]; then
        echo -e "${C_DIM}── last lines of $LOGFILE ──"
        tail -n 15 "$LOGFILE"
        echo -n "$C_RESET"
    fi
    exit 1
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Runners -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# fake_progress <label>: dry run: animate the task bar without touching the system
#   in:  $1 label
#   out: footer animated 0 → 100 %
fake_progress() {
    local i
    for (( i = 0; i <= 100; i += RANDOM % 9 + 3 )); do task "$i" "$1 (dry run)"; sleep 0.03; done
}

# apt reports progress as "dlstatus:<n>:<pct>:<msg>" / "pmstatus:<pkg>:<pct>:<msg>" (APT::Status-Fd).
# Status goes to fd 3, opened inside sudo (sudo closes extra fds). Not fd 1: apt marks its status fd
# close-on-exec, so maintainer scripts would lose stdout and fail ("echo: I/O error").
# Status and normal output share the pipe; normal output is split off into the log.
# apt_step <label> <apt-get args...>: run apt-get with live progress
#   in:  $1 label, the rest goes to apt-get (install, upgrade, purge, update, autoremove ...); DRY_RUN, SUDO
#   out: apt-get's exit status; footer progress; "✓ <pkg>" in pane A per installed package;
#        PKG_LOG entries (R requested, N new, U upgraded); everything else apt prints → LOGFILE
apt_step() {
    local label=$1 line rc p kind=N; shift
    task 0 "$label"
    log_cmd apt-get "$@"
    [[ -n $PKG_LOG ]] || PKG_LOG=$(mktemp)
    [[ $1 == upgrade ]] && kind=U
    if [[ $1 == install ]]; then   # what was asked for (a .deb path counts by its name)
        for p in "${@:2}"; do [[ $p == -* || $p == *=* ]] && continue; p=${p##*/}; printf '%s R %s\n' "$STAGE_IDX" "${p%.deb}"; done >>"$PKG_LOG"
    fi
    if (( DRY_RUN )); then fake_progress "$label"; task 100 "$label"; return 0; fi

    $SUDO env DEBIAN_FRONTEND=noninteractive bash -c 'exec 3>&1 1>&2; exec apt-get "$@"' _ -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        -o Dpkg::Use-Pty=0 -o APT::Status-Fd=3 "$@" </dev/null 2>&1 |
    while IFS= read -r line; do
        if [[ $line =~ ^(dl|pm)status:(.*):([0-9]+)(\.[0-9]*)?:(.*)$ ]]; then
            if [[ ${BASH_REMATCH[1]} == dl ]]; then
                task $(( BASH_REMATCH[3] / 2 )) "$label · ${BASH_REMATCH[5]}"
            else
                task $(( 50 + BASH_REMATCH[3] / 2 )) "$label · ${BASH_REMATCH[5]}"
                if [[ ${BASH_REMATCH[5]} == Installed* ]]; then
                    say "${C_DIM}✓ ${BASH_REMATCH[2]}${C_RESET}"
                    printf '%s %s %s\n' "$STAGE_IDX" "$kind" "${BASH_REMATCH[2]%%:*}" >>"$PKG_LOG"
                fi
            fi
        else
            echo "$line" >>"$LOGFILE"
        fi
    done
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && task 100 "$label"
    return "$rc"
}

# log_cmd <command...>: record the command about to run
#   in:  the command words
#   out: "$ command" in LOGFILE; $UI_DIR/cmd (pane B's header)
log_cmd() {
    echo "\$ $*" >>"$LOGFILE"
    [[ -n $UI_DIR && -d $UI_DIR ]] && printf '%s' "$*" >"$UI_DIR/cmd"
}

# run_step <label> <command...>: run a non-apt command behind the footer
#   in:  $1 label, the rest is the command; DRY_RUN (then nothing runs)
#   out: the command's exit status; its output → LOGFILE
run_step() {
    local label=$1; shift
    task 0 "$label"
    log_cmd "$@"
    if (( DRY_RUN )); then fake_progress "$label"; task 100 "$label"; return 0; fi
    "$@" </dev/null >>"$LOGFILE" 2>&1 || return
    task 100 "$label"
}

# ros_source_ok: is the ROS apt source really there? (the package alone isn't enough)
#   in:  none
#   out: status 0 when ros2-apt-source is installed and ros2.sources + its keyring exist
ros_source_ok() {
    pkg_installed ros2-apt-source && [[ -f /etc/apt/sources.list.d/ros2.sources && -f /usr/share/keyrings/ros2-archive-keyring.gpg ]]
}

# No "cmd | grep -q" under pipefail: grep quits at the first match, cmd dies of SIGPIPE and the check fails at random.
# pkg_installed <package>: is it installed?
#   in:  $1 package name
#   out: status 0 = installed
pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == *"ok installed" ]]; }
# utf8_locale: is the current locale UTF-8?
#   in:  none
#   out: status 0 = yes
utf8_locale()   { [[ $(locale 2>/dev/null) =~ [Uu][Tt][Ff]-?8 ]]; }
# is_installed <distro>: is this ROS 2 distro on disk?
#   in:  $1 distro id
#   out: status 0 when /opt/ros/<distro> exists
is_installed()  { [[ -n $1 && -d /opt/ros/$1 ]]; }
# installed_type <distro>: which install type an installed distro has
#   in:  $1 distro id
#   out: stdout: desktop | ros-base
installed_type() { pkg_installed "ros-$1-desktop" && echo desktop || echo ros-base; }
# detect_installed: list the ROS 2 distros on disk
#   in:  none
#   out: INSTALLED (distro ids from /opt/ros)
detect_installed() { local d; INSTALLED=(); for d in /opt/ros/*; do [[ -d $d ]] && INSTALLED+=("${d##*/}"); done; }
# mod_installed <module id>: are all of a plugin's packages installed?
#   in:  $1 module id (see MODULES); DISTRO
#   out: status 0 = all installed; M_* loaded by mod_get
mod_installed() { local p; mod_get "$1" || return 1; for p in $M_PKGS; do pkg_installed "$p" || return 1; done; }

# has_candidate <package>: can apt install it from the configured sources?
#   in:  $1 package name
#   out: status 0 = apt has a candidate version
has_candidate() { [[ $(apt-cache policy "$1" 2>/dev/null) == *"Candidate: "[0-9]* ]]; }

# fetch <url> [max bytes]: download to stdout (curl if present, else wget, which every Ubuntu ships)
#   in:  $1 URL, $2 optional byte limit (a Range request); FETCH_TIMEOUT (default 5 s)
#   out: stdout: the body; non-zero status on failure
fetch() {
    local opt=()
    if command -v curl >/dev/null; then
        [[ -n $2 ]] && opt=(-r "0-$2")
        curl -fsL --max-time "${FETCH_TIMEOUT:-5}" "${opt[@]}" "$1"
    else
        [[ -n $2 ]] && opt=(--header "Range: bytes=0-$2")
        wget -qO- --timeout="${FETCH_TIMEOUT:-5}" --tries=1 "${opt[@]}" "$1"
    fi
}

# Ask rosdistro (the official distro registry) which ROS 2 distros are alive and which Ubuntu
# each one targets. It runs in the background so the splash is on screen immediately.
DISCOVERY_PID="" DISCOVERY_FILE="" DISCOVERY_TMP=""

# discover_fetch: background job: ROS 2 distros, their status and Ubuntu targets, plus names/dates from the ROS docs
#   in:  network (rosdistro index-v4.yaml, each distribution.yaml head, Releases.rst); DISCOVERY_TMP
#   out: stdout: shell assignments (ROSDISTRO_LIVE, DISTRO_* arrays) for discover_finish; nothing when offline
discover_fetch() {
    local index d status tmp=$DISCOVERY_TMP f ubuntu name rel eol
    fetch "$RELEASES_URL" >"$tmp/_releases" &
    if ! index=$(fetch "$ROSDISTRO_URL/index-v4.yaml"); then wait; return 0; fi
    while read -r d status; do
        DISTRO_STATUS[$d]=$status
        # release_platforms sits at the top of distribution.yaml, so the first 1.5 KB is enough
        [[ $status != end-of-life ]] && fetch "$ROSDISTRO_URL/$d/distribution.yaml" 1500 >"$tmp/$d" &
    done < <(awk '/^  [a-z]+:$/             { name = substr($1, 1, length($1) - 1) }
                  /distribution_status:/     { status = $2 }
                  /distribution_type: ros2/  { print name, status }' <<<"$index")
    wait
    for f in "$tmp"/[a-z]*; do
        ubuntu=$(awk '/^  ubuntu:/ { u = 1; next } u && /^  - / { print $2; next } { u = 0 }' "$f" 2>/dev/null | tr -d "'" | paste -sd' ')
        [[ -n $ubuntu ]] && DISTRO_UBUNTU[${f##*/}]=$ubuntu
    done
    # Releases.rst table rows: ":doc:`Jazzy Jalisco <...>`", then release date, logo, EOL date.
    # Rolling only appears in prose (":doc:`ROS 2 Rolling Ridley <...>`").
    while IFS='|' read -r d name rel eol; do
        DISTRO_NAME[$d]=$name
        [[ -n $rel ]] && DISTRO_REL[$d]=$rel
        [[ -n $eol ]] && DISTRO_EOL[$d]=$eol
    done < <(awk '
        /\* - :doc:`[A-Z][a-z]+ [A-Z][a-z]+ </ { match($0, /`[^<]+</); name = substr($0, RSTART + 1, RLENGTH - 3); n = 1; next }
        n == 1 { rel = $0; sub(/^ *- /, "", rel); n = 2; next }
        n == 2 { n = 3; next }
        n == 3 { eol = $0; sub(/^ *- /, "", eol); split(name, w, " "); print tolower(w[1]) "|" name "|" rel "|" eol; n = 0; next }
        /:doc:`ROS 2 [A-Z][a-z]+ [A-Z][a-z]+ </ { match($0, /ROS 2 [A-Z][a-z]+ [A-Z][a-z]+/); name = substr($0, RSTART + 6, RLENGTH - 6)
                                                  split(name, w, " "); print tolower(w[1]) "|" name "||" }' "$tmp/_releases" 2>/dev/null)
    (( ${#DISTRO_UBUNTU[@]} )) || return 0
    echo ROSDISTRO_LIVE=1
    declare -p DISTRO_STATUS DISTRO_UBUNTU DISTRO_NAME DISTRO_REL DISTRO_EOL | sed 's/^declare -A /declare -gA /'
}

# discover_start: start discover_fetch in the background
#   in:  none
#   out: DISCOVERY_PID, DISCOVERY_FILE, DISCOVERY_TMP
discover_start() {
    DISCOVERY_FILE=$(mktemp) DISCOVERY_TMP=$(mktemp -d)   # owned here so it's removed even if the job is cut off
    discover_fetch >"$DISCOVERY_FILE" 2>/dev/null &
    DISCOVERY_PID=$!
}

# discover_finish: wait for the discovery job (max 5 s, animating its splash rows), then pick distros for this Ubuntu
#   in:  DISCOVERY_*, CODENAME, FALLBACK_UBUNTU (when rosdistro was unreachable)
#   out: DISTRO_UBUNTU, DISTRO_STATUS, DISTRO_NAME/REL/EOL, ROSDISTRO_LIVE, VALID_DISTROS, RECOMMENDED; splash rows updated
discover_finish() {
    local d t=0
    while kill -0 "$DISCOVERY_PID" 2>/dev/null && (( t++ < 50 )); do   # GitHub can be slow; give up after 5 s
        splash_set Available "${C_CUR}$(spin_frame)${C_RESET} ${C_DIM}acquiring distro list from rosdistro...${C_RESET}"
        splash_set Recommend "${C_CUR}$(spin_frame)${C_RESET} ${C_DIM}checking what fits this machine...${C_RESET}"
        sleep 0.1
    done
    pkill -P "$DISCOVERY_PID" 2>/dev/null; kill "$DISCOVERY_PID" 2>/dev/null
    [[ -s $DISCOVERY_FILE ]] && eval "$(<"$DISCOVERY_FILE")"
    rm -rf "$DISCOVERY_FILE" "$DISCOVERY_TMP"; DISCOVERY_PID=""

    if (( ! ROSDISTRO_LIVE )); then
        for d in "${!FALLBACK_UBUNTU[@]}"; do
            DISTRO_UBUNTU[$d]=${FALLBACK_UBUNTU[$d]}
            DISTRO_STATUS[$d]=$([[ $d == rolling ]] && echo rolling || echo active)
        done
    fi
    VALID_DISTROS=() RECOMMENDED=""
    for d in $(printf '%s\n' "${!DISTRO_UBUNTU[@]}" | sort); do
        [[ " ${DISTRO_UBUNTU[$d]} " == *" $CODENAME "* ]] && VALID_DISTROS+=("$d")
    done
    # distros are alphabetical by release, so the first stable match is the oldest one: usually the LTS
    for d in "${VALID_DISTROS[@]}"; do
        [[ ${DISTRO_STATUS[$d]} != rolling ]] && { RECOMMENDED=$d; break; }
    done
    splash_set Available "$(available_text)"
    splash_set Recommend "$(recommend_text)"
    splash_set "ROS 2" "$(installed_text)"
}

# discover_distros: discovery in one blocking call, for scripts that source this file
#   in:  none
#   out: see discover_finish
discover_distros() { discover_start; discover_finish; }

# available_text: the splash's "Available" value
#   in:  VALID_DISTROS, ROSDISTRO_LIVE
#   out: stdout
available_text() {
    local d names=()
    for d in "${VALID_DISTROS[@]}"; do names+=("$(dname "$d")"); done
    printf '%s · %s' "$( (( ${#names[@]} )) && join ", " "${names[@]}" || echo "${C_ERR}none for $(ubuntu_name "$CODENAME")${C_RESET}")" \
        "$( (( ROSDISTRO_LIVE )) && echo 'live from rosdistro' || echo "${C_ERR}built-in list${C_RESET} (rosdistro slow or unreachable)")"
}

# installed_text: the splash's "ROS 2" value (installed distros, and the one sourced now)
#   in:  INSTALLED, ROS_DISTRO
#   out: stdout
installed_text() {
    local d names=()
    for d in "${INSTALLED[@]}"; do names+=("$(dname "$d")"); done
    printf '%s%s' "$( (( ${#names[@]} )) && echo "${C_DONE}$(join ", " "${names[@]}") installed${C_RESET}" || echo "not installed")" \
        "$([[ -n $ROS_DISTRO ]] && echo " · sourced: $(dname "$ROS_DISTRO")")"
}

# join <separator> <words...>: join words with a separator
#   in:  $1 separator, the rest are the words
#   out: stdout
join() { local sep=$1 out=$2; shift 2; for x in "$@"; do out+="$sep$x"; done; printf '%s' "$out"; }

# dname <distro>: a distro's full name ("Jazzy Jalisco")
#   in:  $1 distro id; DISTRO_NAME (from the ROS docs), else FALLBACK_NAME, else the id itself
#   out: stdout
dname() { printf '%s' "${DISTRO_NAME[$1]:-${FALLBACK_NAME[$1]:-$1}}"; }

# ubuntu_name <codename>: Ubuntu's full release name ("Ubuntu 24.04 LTS (Noble Numbat)")
#   in:  $1 codename; /usr/share/distro-info/ubuntu.csv, else os-release, else FALLBACK_UBUNTU_NAME
#   out: stdout
ubuntu_name() {
    local v n line
    line=$(grep -m1 ",$1," /usr/share/distro-info/ubuntu.csv 2>/dev/null)
    if [[ -n $line ]]; then IFS=, read -r v n _ <<<"$line"; printf 'Ubuntu %s (%s)' "$v" "$n"
    elif [[ $1 == "$CODENAME" ]]; then printf 'Ubuntu %s' "$VERSION"
    elif [[ -n ${FALLBACK_UBUNTU_NAME[$1]} ]]; then printf 'Ubuntu %s (%s)' "${FALLBACK_UBUNTU_NAME[$1]%|*}" "${FALLBACK_UBUNTU_NAME[$1]#*|}"
    else printf '%s' "$1"; fi
}

# ubuntu_names <codenames>: ubuntu_name for a space separated list
#   in:  $1 codenames, e.g. "jammy noble"
#   out: stdout: comma separated
ubuntu_names() { local c out=(); for c in $1; do out+=("$(ubuntu_name "$c")"); done; join ", " "${out[@]}"; }

# lifespan <distro>: one-line support summary
#   in:  $1 distro id; DISTRO_STATUS, DISTRO_EOL
#   out: stdout: "supported until …" / "end of life since …" / "rolling release, can break"
lifespan() {
    if [[ ${DISTRO_STATUS[$1]} == rolling ]]; then printf 'rolling release, can break'
    elif [[ ${DISTRO_STATUS[$1]} == end-of-life ]]; then printf 'end of life%s' "${DISTRO_EOL[$1]:+ since ${DISTRO_EOL[$1]}}"
    elif [[ -n ${DISTRO_EOL[$1]} ]]; then printf 'supported until %s' "${DISTRO_EOL[$1]}"
    else printf '%s' "${DISTRO_STATUS[$1]}"; fi
}

# recommend_text: the splash's "Recommend" value
#   in:  RECOMMENDED, CODENAME
#   out: stdout
recommend_text() {
    if [[ -z $RECOMMENDED ]]; then printf '%s' "${C_ERR}no ROS 2 distro for $(ubuntu_name "$CODENAME") yet${C_RESET}"
    elif is_installed "$RECOMMENDED"; then printf '%s %s' "$(dname "$RECOMMENDED")" "${C_DONE}✓ already installed${C_RESET}"
    else printf '%s · %s' "${C_DONE}$(dname "$RECOMMENDED")${C_RESET}" "ros-$RECOMMENDED-$(detect_type)"; fi
}

# mod_get <module id>: load one MODULES entry
#   in:  $1 module id; DISTRO (fills the "@" in package names)
#   out: M_ID, M_NAME, M_DESC, M_PKGS; status 1 if there is no such module
mod_get() {
    local m
    for m in "${MODULES[@]}"; do
        if [[ ${m%%|*} == "$1" ]]; then
            IFS='|' read -r M_ID M_NAME M_DESC M_PKGS <<<"$m"
            M_PKGS=${M_PKGS//@/$DISTRO}
            return 0
        fi
    done
    return 1
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Install steps -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# needs_prepare: does this machine need the Prepare stage? (one that already has ROS usually doesn't)
#   in:  PREREQS
#   out: status 0 = needed (locale isn't UTF-8 or a prerequisite is missing)
needs_prepare() {
    local p
    utf8_locale || return 0
    for p in "${PREREQS[@]}"; do pkg_installed "$p" || return 0; done
    return 1
}

# step_prepare: Prepare stage: apt update, the prerequisites, a UTF-8 locale
#   in:  PREREQS, SUDO
#   out: status; LANG exported when the locale was set up
step_prepare() {
    apt_step "Refreshing package lists" update || return
    apt_step "Installing prerequisites" install "${PREREQS[@]}" || return
    if utf8_locale; then
        ok "UTF-8 locale already set"
    else
        run_step "Generating en_US.UTF-8" $SUDO locale-gen en_US en_US.UTF-8 || return
        run_step "Setting system locale" $SUDO update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 || return
        export LANG=en_US.UTF-8
        ok "Locale set to en_US.UTF-8"
    fi
}

# step_sources: Sources stage: universe on, legacy ros2.list gone, ros2-apt-source installed (or repaired), apt update
#   in:  CODENAME, DRY_RUN, SUDO; GitHub for the latest ros2-apt-source release
#   out: status
step_sources() {
    if grep -rqsE '^[^#]*\buniverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/; then
        ok "universe repository already enabled"
    else
        run_step "Enabling universe repository" $SUDO add-apt-repository -y universe || return
    fi

    # v1 wrote ros2.list with the old (now expired) key; it clashes with ros2-apt-source
    if [[ -f /etc/apt/sources.list.d/ros2.list ]]; then
        run_step "Removing legacy ros2.list" $SUDO rm -f /etc/apt/sources.list.d/ros2.list || return
        ok "Removed legacy ros2.list"
    fi

    if ros_source_ok; then
        ok "ros2-apt-source already installed"
    else
        local ver=dry-run tmp repair=()
        # registered as installed but its files were deleted: reinstall and restore the missing config file
        pkg_installed ros2-apt-source && repair=(--reinstall -o Dpkg::Options::=--force-confmiss)
        if (( ! DRY_RUN )); then
            ver=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest |
                  grep -F '"tag_name"' | awk -F'"' '{print $4}')
            [[ -n $ver ]] || { warn "Couldn't reach GitHub to look up ros2-apt-source"; return 1; }
        fi
        tmp=$(mktemp -d) && chmod 755 "$tmp"
        run_step "Downloading ros2-apt-source $ver" curl -fsSL -o "$tmp/ros2-apt-source.deb" \
            "https://github.com/ros-infrastructure/ros-apt-source/releases/download/$ver/ros2-apt-source_$ver.${CODENAME}_all.deb" || return
        apt_step "$( (( ${#repair[@]} )) && echo Repairing || echo Installing) ros2-apt-source" install "${repair[@]}" "$tmp/ros2-apt-source.deb" || { rm -rf "$tmp"; return 1; }
        rm -rf "$tmp"
        ros_source_ok || (( DRY_RUN )) || { warn "ros2-apt-source is installed but /etc/apt/sources.list.d/ros2.sources is still missing"; return 1; }
        ok "ROS 2 apt source $( (( ${#repair[@]} )) && echo repaired || echo added) ($ver)"
    fi
    apt_step "Refreshing package lists" update
}

# step_upgrade: Upgrade stage: apt-get upgrade
#   in:  none
#   out: status
step_upgrade() { apt_step "Upgrading system packages" upgrade; }

# step_ros: ROS 2 stage: install ros-<distro>-<type>
#   in:  DISTRO, ROS_TYPE
#   out: status (1 when the package isn't available for this Ubuntu)
step_ros() {
    local pkg="ros-$DISTRO-$ROS_TYPE"
    if (( ! DRY_RUN )) && ! has_candidate "$pkg"; then
        warn "$pkg isn't available for $(ubuntu_name "$CODENAME")"
        return 1
    fi
    apt_step "Installing $pkg" install "$pkg" || return
    ok "ROS 2 $(dname "$DISTRO") ($ROS_TYPE) installed"
}

# step_module <module id>: one plugin stage; packages this distro doesn't have are skipped with a warning
#   in:  $1 module id
#   out: status
step_module() {
    local p pkgs=()
    mod_get "$1"
    for p in $M_PKGS; do
        if (( DRY_RUN )) || has_candidate "$p"; then pkgs+=("$p")
        else warn "Skipping $p (not available for $(dname "$DISTRO"))"; fi
    done
    (( ${#pkgs[@]} )) || return 0
    apt_step "Installing $M_NAME" install "${pkgs[@]}" || return
    ok "$M_DESC"
}

# step_packages: Packages stage: anything picked from the repository or given with --packages
#   in:  EXTRA_PKGS
#   out: status
step_packages() {
    local p pkgs=()
    for p in "${EXTRA_PKGS[@]}"; do
        if (( DRY_RUN )) || has_candidate "$p"; then pkgs+=("$p")
        else warn "Skipping $p (not available for $(dname "$DISTRO"))"; fi
    done
    (( ${#pkgs[@]} )) || return 0
    apt_step "Installing ${#pkgs[@]} package$( (( ${#pkgs[@]} > 1 )) && echo s)" install "${pkgs[@]}" || return
    ok "${pkgs[*]}"
}

# step_remove: purge every ros-<target>-* package and stop the rc files sourcing it
#   in:  TARGET
#   out: status; ~/.bashrc and ~/.zshrc edited by rc_unsource
step_remove() {
    apt_step "Purging ros-$TARGET-*" purge "~n^ros-$TARGET-" || return
    local rc
    for rc in ~/.bashrc "${ZDOTDIR:-$HOME}/.zshrc"; do rc_unsource "$rc" "$TARGET"; done
    ok "ROS 2 $(dname "$TARGET") removed"
}

# step_autoremove: Cleanup stage: apt-get autoremove
#   in:  none
#   out: status
step_autoremove() { apt_step "Removing unused dependencies" autoremove; }

# step_rosdep: rosdep stage: rosdep init (once per machine), then rosdep update
#   in:  SUDO
#   out: status
step_rosdep() {
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        run_step "rosdep init" $SUDO rosdep init || return
    fi
    run_step "rosdep update" rosdep update || return
    ok "rosdep ready"
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Flow -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# usage: the --help text
#   in:  MODULES, RM_VERSION
#   out: stdout
usage() {
    cat <<EOF

Usage: ros-manager [OPTIONS]

  -v, --version DISTRO     ROS 2 distro (default: recommended for this Ubuntu, from rosdistro)
  -t, --type TYPE          desktop | base   (default: detected from the system)
  -f, --force TYPE         v1 alias: desktop | server
  -w, --with LIST          plugins, comma separated: $(printf '%s,' "${MODULES[@]%%|*}" | sed 's/,$//')
  -d, --dev                same as --with devtools
  -p, --packages LIST      any packages from the ROS repo, comma separated (nav2_bt_navigator,
                           nav2-bt-navigator and ros-<distro>-nav2-bt-navigator all work)
      --no-upgrade         skip 'apt-get upgrade'
      --no-rc              don't add 'source /opt/ros/<distro>/setup.<bash|zsh>' to ~/.bashrc / ~/.zshrc
                           (--no-bashrc works too)
      --remove DISTRO      uninstall a ROS 2 distro
  -y, --yes                no questions, use defaults for anything not given
  -n, --dry-run            show the whole flow without changing anything
  -h, --help               show this help

Example: ros-manager -v jazzy -t desktop -w gazebo,nav2,urdf -d -y

ROS Manager v$RM_VERSION · MIT © 2025-2026 Koustav Betal · github.com/koustavbetal/ros_manager
EOF
}

# parse_args <args...>: read the command line
#   in:  the script's arguments
#   out: DISTRO, ROS_TYPE, WITH, PKGS_ARG, DO_UPGRADE, ADD_BASHRC, REMOVE, ASSUME_YES, DRY_RUN;
#        -h prints help and exits, an unknown option dies
parse_args() {
    while (( $# )); do
        case $1 in
            -v|--version)  DISTRO=$2; shift ;;
            -t|--type)     ROS_TYPE=$2; shift ;;
            -f|--force)    ROS_TYPE=$2; [[ $ROS_TYPE == server ]] && ROS_TYPE=base; shift ;;
            -w|--with)     WITH+=" ${2//,/ }"; shift ;;
            -d|--dev)      WITH+=" devtools" ;;
            -p|--packages) PKGS_ARG+=" ${2//,/ }"; shift ;;
            --no-upgrade)  DO_UPGRADE=0 ;;
            --no-rc|--no-bashrc) ADD_BASHRC=0 ;;
            --remove)      REMOVE=$2; shift ;;
            -y|--yes)      ASSUME_YES=1 ;;
            -n|--dry-run)  DRY_RUN=1 ;;
            -h|--help)     usage; exit 0 ;;
            *)             usage; die "Unknown option: $1" ;;
        esac
        shift
    done
    [[ $ROS_TYPE == base ]] && ROS_TYPE=ros-base
}

# detect_shell: the login shell (not the bash running this script) and the rc file ROS goes into
#   in:  passwd entry, else SHELL
#   out: LOGIN_SHELL; RC_SHELL = bash | zsh, RC_FILE
detect_shell() {
    LOGIN_SHELL=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7); LOGIN_SHELL=${LOGIN_SHELL:-$SHELL}; LOGIN_SHELL=${LOGIN_SHELL##*/}
    if [[ $LOGIN_SHELL == zsh ]] && command -v zsh >/dev/null; then RC_SHELL=zsh RC_FILE=${ZDOTDIR:-$HOME}/.zshrc
    else RC_SHELL=bash RC_FILE=$HOME/.bashrc; fi
}

# detect_type: default install type for this machine
#   in:  none
#   out: stdout: desktop when ubuntu-desktop(-minimal) is installed, else ros-base
detect_type() {
    if [[ $(dpkg-query -W -f='${Status}\n' ubuntu-desktop ubuntu-desktop-minimal 2>/dev/null) == *"ok installed"* ]]; then
        echo desktop
    else
        echo ros-base
    fi
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Splash -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# neofetch-style landing screen: ROS logo on the left, everything we know about the machine on the right.
INFO_K=() INFO_V=()
# info <label> <value>: add one splash row
#   in:  $1 label, $2 value (may hold colours)
#   out: appends to INFO_K, INFO_V
info() { INFO_K+=("$1"); INFO_V+=("$2"); }

# sys_info: collect the splash rows (OS, hardware, locale, shell, ROS state, privileges)
#   in:  the system
#   out: INFO_K, INFO_V; LOGIN_SHELL / RC_* (via detect_shell)
sys_info() {
    local pkg ver kb_total kb_avail disk model src

    info OS "Ubuntu $VERSION"

    # Edition: same check v1 used (ubuntu-desktop / ubuntu-server meta-packages)
    for pkg in ubuntu-desktop ubuntu-desktop-minimal ubuntu-server; do
        ver=$(dpkg-query -W -f='${Status} ${Version}' "$pkg" 2>/dev/null) || continue
        [[ $ver == *"ok installed"* ]] && break
        ver=""
    done
    if [[ -n $ver ]]; then
        info Edition "$([[ $pkg == ubuntu-server ]] && echo Server || echo Desktop) · $pkg ${ver##* }"
    else
        info Edition "unknown (no ubuntu-desktop/server package) · defaults to ros-base"
    fi

    if [[ -f /.dockerenv ]]; then model="Docker container"
    elif [[ -r /proc/device-tree/model ]]; then model=$(tr -d '\0' </proc/device-tree/model)
    else model=$(cat /sys/class/dmi/id/product_name 2>/dev/null); fi
    [[ -n $model ]] && info Host "$model"

    info Session "$([[ -n $DISPLAY || -n $WAYLAND_DISPLAY ]] && echo "${XDG_CURRENT_DESKTOP:-desktop} · ${XDG_SESSION_TYPE:-x11}" || echo "headless (${XDG_SESSION_TYPE:-tty})")"
    info Kernel "$(uname -r) · $(dpkg --print-architecture)"
    info CPU "$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1) · $(nproc) threads"

    kb_total=$(awk '/^MemTotal/ { print $2 }' /proc/meminfo)
    kb_avail=$(awk '/^MemAvailable/ { print $2 }' /proc/meminfo)
    info Memory "$(( (kb_total - kb_avail) / 1048576 )) / $(( kb_total / 1048576 )) GiB used"

    disk=$(df -Pk / | awk 'NR == 2 { print $4 }')
    if (( disk < 6 * 1048576 )); then
        info Disk "${C_ERR}$(( disk / 1048576 )) GiB free on /${C_RESET} · desktop + plugins need ~6 GiB"
    else
        info Disk "$(( disk / 1048576 )) GiB free on /"
    fi

    if utf8_locale; then info Locale "${LANG:-unset} ${C_DONE}✓ UTF-8${C_RESET}"
    else info Locale "${LANG:-unset} ${C_ERR}✗ not UTF-8${C_RESET} · will be set up"; fi
    detect_shell
    case $LOGIN_SHELL/$RC_SHELL in
        bash/bash) info Shell "bash ${BASH_VERSION%%(*} ${C_DONE}✓ ROS supports it${C_RESET} · setup.bash → ${RC_FILE/#$HOME/\~}" ;;
        zsh/zsh)   info Shell "zsh $(zsh --version 2>/dev/null | awk '{ print $2 }') ${C_DONE}✓ ROS supports it${C_RESET} · setup.zsh → ${RC_FILE/#$HOME/\~}" ;;
        *)         info Shell "$LOGIN_SHELL ${C_WARN}✗ no ROS setup file for it${C_RESET} · setup.bash → ${RC_FILE/#$HOME/\~} (use bash or zsh for ROS)" ;;
    esac

    # ROS state (v1 showed installed distros; we also show what's sourced and how apt is set up)
    info "ROS 2" "$(installed_text)"   # names refined in place once the docs arrive
    if src=$(dpkg-query -W -f='${Status} ${Version}' ros2-apt-source 2>/dev/null) && [[ $src == *"ok installed"* ]] && ! ros_source_ok; then
        info "ROS apt" "${C_ERR}ros2-apt-source ${src##* } is broken${C_RESET} (ros2.sources or its key is missing) · will be repaired"
    elif [[ $src == *"ok installed"* ]]; then
        info "ROS apt" "ros2-apt-source ${src##* }$([[ -f /etc/apt/sources.list.d/ros2.list ]] && echo " ${C_ERR}+ legacy ros2.list (will be removed)${C_RESET}")"
    elif [[ -f /etc/apt/sources.list.d/ros2.list ]]; then
        info "ROS apt" "${C_ERR}legacy ros2.list${C_RESET} (expired key) · will be replaced"
    else
        info "ROS apt" "not configured"
    fi
    info Available "${C_DIM}...${C_RESET}"   # filled in place once discovery finishes
    info Recommend "${C_DIM}...${C_RESET}"

    if (( EUID == 0 )); then info Privilege root
    elif sudo -n true 2>/dev/null; then info Privilege "sudo (cached)"
    else info Privilege "sudo (will ask for password)"; fi
    info Log "$LOGFILE"
}

# fit <text> <width>: fitv for use inside $(...)
#   in:  $1 text, $2 width
#   out: stdout
fit() { fitv "$1" "$2"; printf '%s' "$FIT"; }

SPLASH_ROWS=0 SPLASH_LW=25 SPLASH_VW=60
declare -A SPLASH_IDX=()

# splash_set <label> <text>: rewrite one splash row in place (cursor stays where it was)
#   in:  $1 row label, $2 new value; SPLASH_IDX, SPLASH_ROWS
#   out: the row redrawn; nothing without a terminal or for an unknown label
splash_set() {
    [[ -n ${SPLASH_IDX[$1]} && -t 1 ]] || return 0
    printf '\e7\e[%dA\r\e[%dG\e[K%s%-10s%s %s\e8' $(( SPLASH_ROWS - SPLASH_IDX[$1] + 1 )) "$SPLASH_LW" \
        "$C_CUR" "$1" "$C_RESET" "$(fit "$2" "$SPLASH_VW")"
}

# splash: clear the screen and draw the landing screen: ROS logo left, sys_info right
#   in:  INFO_K, INFO_V (filled here), COLS
#   out: SPLASH_ROWS, SPLASH_LW, SPLASH_VW, SPLASH_IDX (for splash_set)
splash() {
    local logo=() dot_t="▄██▄" dot_b="▀██▀" r c line i rows lw=25 vw label
    local LC_ALL=C.UTF-8
    sys_info

    for r in 0 1 2; do   # the ROS 3x3 dots, coloured along the progress-bar ramp
        line=" "; for c in 0 1 2; do line+=$'\e[38;5;'"${RAMP_256[r * 3 + c]}m$dot_t  "; done; logo+=("$line$C_RESET")
        line=" "; for c in 0 1 2; do line+=$'\e[38;5;'"${RAMP_256[r * 3 + c]}m$dot_b  "; done; logo+=("$line$C_RESET")
        (( r < 2 )) && logo+=("")
    done
    logo+=("" " ${C_CUR}${C_BOLD}ROS Manager${C_RESET}" " ${C_DIM}v$RM_VERSION$( (( DRY_RUN )) && echo ' · dry run')${C_RESET}")

    [[ -t 1 ]] && printf '\e[H\e[2J'
    echo
    label="$(whoami)@$(hostname)"
    INFO_K=("" "" "${INFO_K[@]}") INFO_V=("${C_CUR}${C_BOLD}$label${C_RESET}" "${C_SEP}$(printf '─%.0s' $(seq 1 ${#label}))${C_RESET}" "${INFO_V[@]}")
    (( COLS = ${COLUMNS:-$(tput cols 2>/dev/null || echo 100)} ))
    (( COLS < 70 )) && { logo=(); lw=1; }
    vw=$(( COLS - lw - 12 ))
    rows=$(( ${#INFO_K[@]} > ${#logo[@]} ? ${#INFO_K[@]} : ${#logo[@]} ))
    SPLASH_ROWS=$rows SPLASH_LW=$lw SPLASH_VW=$vw
    for i in "${!INFO_K[@]}"; do [[ -n ${INFO_K[i]} ]] && SPLASH_IDX[${INFO_K[i]}]=$i; done
    for (( i = 0; i < rows; i++ )); do
        printf '\e[2K%s\e[%dG' "${logo[i]}" "$lw"
        if [[ -n ${INFO_K[i]} ]]; then printf '%s%-10s%s %s\n' "$C_CUR" "${INFO_K[i]}" "$C_RESET" "$(fit "${INFO_V[i]}" "$vw")"
        else printf '%s\n' "${INFO_V[i]}"; fi
    done
    echo
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Inline prompts -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# Drawn right under the splash (no full-screen dialog). Keys: ↑/↓ or j/k, enter, tab / shift+tab, a, q.
# read_key [timeout]: read one key press, escape sequences included
#   in:  $1 optional timeout in seconds
#   out: KEY: up down enter tab backtab esc space backspace clear yes no all quit char other none (timeout);
#        CH: the printable character, for typing
read_key() {
    local k rest
    KEY=none CH=""
    IFS= read -rsn1 ${1:+-t "$1"} k || return 0
    if [[ $k == $'\e' ]]; then IFS= read -rsn2 -t 0.05 rest; k+=$rest; fi
    case $k in
        $'\e[A')       KEY=up ;;
        $'\e[B')       KEY=down ;;
        $'\e[Z')       KEY=backtab ;;   # shift+tab
        $'\e')         KEY=esc ;;
        $'\e'*)        KEY=other ;;
        '')            KEY=enter ;;
        $'\t')         KEY=tab ;;
        $'\x7f'|$'\b') KEY=backspace ;;
        $'\x15')       KEY=clear ;;   # Ctrl+U
        ' ')           KEY=space CH=" " ;;
        k)             KEY=up   CH=$k ;;
        j)             KEY=down CH=$k ;;
        [yY])          KEY=yes  CH=$k ;;
        [nN])          KEY=no   CH=$k ;;
        [aA])          KEY=all  CH=$k ;;
        [qQ])          KEY=quit CH=$k ;;
        [[:print:]])   KEY=char CH=$k ;;
        *)             KEY=other ;;
    esac
}

# keys <key> <label> ...: a key help line (main keys first, optional ones last)
#   in:  key/label pairs
#   out: KEYS: keys in C_WARN, labels dim
keys() {
    KEYS=""
    while (( $# )); do KEYS+="${KEYS:+$C_DIM · }$C_WARN$1$C_RESET$C_DIM $2"; shift 2; done
    KEYS+=$C_RESET
}

# bye: quit before anything changed
#   in:  none
#   out: never returns: exit 0
bye() { tput cnorm; echo -e "\n${C_DIM}  Nothing was changed. Bye!${C_RESET}\n"; exit 0; }

# answered <question> <answer>: the one line a finished prompt collapses into
#   in:  $1 question, $2 answer
#   out: stdout
answered() { echo -e "${C_DONE}✓${C_RESET} ${C_BOLD}$1${C_RESET} ${C_CUR}$2${C_RESET}"; }

# pick <question> <default> <value>[|label] <description> ...: single-choice list
#   in:  $1 question, $2 default value, then value/description pairs; CAN_BACK, PICK_TINT (caller's local:
#        colours the selectable labels). Value prefixes, none selectable: "#" section header, "~" grey,
#         "+" done (green), "^" caution (yellow), "!" end of life (red)
#   out: PICK and the answer line; status 1 (nothing printed) on shift+tab when CAN_BACK is set
pick() {
    local LC_ALL=C.UTF-8 q=$1 def=$2 vals=() labels=() kinds=() descs=() i sel=-1 n w=0 dw v k; shift 2
    while (( $# )); do
        v=$1
        case $v in '#'*) k=head ;; '~'*) k=grey ;; '+'*) k=done ;; '^'*) k=warn ;; '!'*) k=eol ;; *) k=opt ;; esac
        [[ $k != opt ]] && v=${v:1}
        kinds+=("$k") vals+=("${v%%|*}") labels+=("${v#*|}") descs+=("$2")
        shift 2
    done
    n=${#vals[@]}
    for i in "${!vals[@]}"; do
        [[ ${kinds[i]} == head ]] && continue
        (( ${#labels[i]} > w )) && w=${#labels[i]}
        if [[ ${kinds[i]} == opt ]]; then
            (( sel < 0 )) && sel=$i
            [[ ${vals[i]} == "$def" ]] && sel=$i
        fi
    done
    (( sel >= 0 )) || die "Nothing to choose from for: $q"
    dw=$(( $(tput cols) - w - 8 ))
    if (( CAN_BACK )); then keys "↑/↓" move ENTER select SHIFT+TAB back Q quit; else keys "↑/↓" move ENTER select Q quit; fi
    echo -e "${C_CUR}?${C_RESET} ${C_BOLD}$q${C_RESET}  $KEYS"
    tput civis; [[ -t 0 ]] && stty -echo   # held keys must not echo between reads
    while :; do
        for i in "${!vals[@]}"; do
            case ${kinds[i]} in
                head) printf '\e[2K  %s──%s %s%s%s\n' "$C_SEP" "$C_RESET" "$C_BOLD" "${labels[i]}" "$C_RESET" ;;
                grey) printf '\e[2K    %s%-*s  %s%s\n' "$C_DIM" "$w" "${labels[i]}" "$(fit "${descs[i]}" "$dw")" "$C_RESET" ;;
                done|warn|eol)
                      case ${kinds[i]} in done) k=$C_DONE ;; warn) k=$C_WARN ;; *) k=$C_ERR ;; esac
                      printf '\e[2K    %s%-*s%s  %s%s%s\n' "$k" "$w" "${labels[i]}" "$C_RESET" "$C_DIM" "$(fit "${descs[i]}" "$dw")" "$C_RESET" ;;
                opt)
                    if (( i == sel )); then printf '\e[2K  %s❯%s %s%-*s%s  %s\n' "$C_CUR$C_BOLD" "$C_RESET" "${PICK_TINT:-$C_CUR}$C_BOLD" "$w" "${labels[i]}" "$C_RESET" "$(fit "${descs[i]}" "$dw")"
                    else printf '\e[2K    %s%-*s%s  %s%s%s\n' "$PICK_TINT" "$w" "${labels[i]}" "$C_RESET" "$C_DIM" "$(fit "${descs[i]}" "$dw")" "$C_RESET"; fi ;;
            esac
        done
        read_key
        case $KEY in
            up)    for (( i = 0; i < n; i++ )); do sel=$(( (sel - 1 + n) % n )); [[ ${kinds[sel]} == opt ]] && break; done ;;
            down)  for (( i = 0; i < n; i++ )); do sel=$(( (sel + 1) % n )); [[ ${kinds[sel]} == opt ]] && break; done ;;
            enter|tab) break ;;
            backtab) (( CAN_BACK )) && { printf '\e[%dA\e[J' $(( n + 1 )); tput cnorm; [[ -t 0 ]] && stty echo; return 1; } ;;
            quit|esc) bye ;;
        esac
        printf '\e[%dA' "$n"
    done
    printf '\e[%dA\e[J' $(( n + 1 ))   # collapse the list into a one-line answer
    tput cnorm; [[ -t 0 ]] && stty echo
    PICK=${vals[sel]}
    answered "$q" "${labels[sel]}"
}

# distro_pick <question>: every ROS 2 distro in tiers; only active ones built for this Ubuntu are selectable
#   in:  $1 question; VALID_DISTROS, DISTRO_STATUS, RECOMMENDED
#   out: PICK; status 1 on shift+tab
distro_pick() {
    local items=() rest=() eol=() d PICK_TINT=$C_DONE   # tiers: green = built for this Ubuntu, yellow = elsewhere, red = EOL
    items+=("#Built for $(ubuntu_name "$CODENAME")" "")
    for d in "${VALID_DISTROS[@]}"; do
        if is_installed "$d"; then items+=("+$d|$(dname "$d")" "✓ installed · $(lifespan "$d")")
        else items+=("$d|$(dname "$d")" "$(lifespan "$d")$([[ $d == "$RECOMMENDED" ]] && echo "  ${C_DONE}★ recommended${C_RESET}")"); fi
    done
    for d in $(printf '%s\n' "${!DISTRO_STATUS[@]}" | sort); do
        [[ " ${VALID_DISTROS[*]} " == *" $d "* ]] && continue
        if [[ ${DISTRO_STATUS[$d]} == end-of-life ]]; then
            eol+=("!$d|$(dname "$d")" "$(lifespan "$d")")
        else
            rest+=("^$d|$(dname "$d")" "$(lifespan "$d") · ${DISTRO_UBUNTU[$d]:+$(ubuntu_names "${DISTRO_UBUNTU[$d]}")}")
        fi
    done
    (( ${#rest[@]} )) && items+=("#Active, not built for your Ubuntu" "" "${rest[@]}")
    (( ${#eol[@]} ))  && items+=("#End of life" "" "${eol[@]}")
    pick "$1" "$RECOMMENDED" "${items[@]}"
}

# check <question> <value> <description> <on|off|lock> ...: multi-choice list (lock = installed, fixed)
#   in:  $1 question, then value/description/state triples
#   out: CHECKED (space separated) and the answer line
check() {
    local LC_ALL=C.UTF-8 q=$1 vals=() descs=() on=() i sel=0 n w=0 dw all mark; shift
    while (( $# )); do vals+=("$1"); descs+=("$2"); on+=("$3"); shift 3; done
    n=${#vals[@]}
    for i in "${!vals[@]}"; do (( ${#vals[i]} > w )) && w=${#vals[i]}; done
    for i in "${!vals[@]}"; do [[ ${on[i]} != lock ]] && { sel=$i; break; }; done   # start on the first choosable row
    dw=$(( $(tput cols) - w - 10 ))
    keys "↑/↓" move ENTER toggle TAB done A all
    echo -e "${C_CUR}?${C_RESET} ${C_BOLD}$q${C_RESET}  $KEYS"
    tput civis; [[ -t 0 ]] && stty -echo
    while :; do
        for i in "${!vals[@]}"; do
            case ${on[i]} in on) mark="${C_DONE}◉" ;; lock) mark="${C_DONE}✓" ;; *) mark="${C_TODO}○" ;; esac
            if (( i == sel )); then printf '\e[2K  %s❯%s %s %s%-*s%s  %s\n' "$C_CUR" "$C_RESET" "$mark" "$C_CUR$C_BOLD" "$w" "${vals[i]}" "$C_RESET" "${descs[i]:0:$dw}"
            else printf '\e[2K    %s%s %-*s  %s%s\n' "$mark" "$C_RESET$C_DIM" "$w" "${vals[i]}" "${descs[i]:0:$dw}" "$C_RESET"; fi
        done
        read_key
        case $KEY in
            up)    for (( i = 0; i < n; i++ )); do sel=$(( (sel - 1 + n) % n )); [[ ${on[sel]} != lock ]] && break; done ;;
            down)  for (( i = 0; i < n; i++ )); do sel=$(( (sel + 1) % n )); [[ ${on[sel]} != lock ]] && break; done ;;
            enter) case ${on[sel]} in on) on[sel]=off ;; off) on[sel]=on ;; esac ;;
            all)   all=off; for i in "${!on[@]}"; do [[ ${on[i]} == off ]] && all=on; done
                   for i in "${!on[@]}"; do [[ ${on[i]} != lock ]] && on[i]=$all; done ;;
            tab)   break ;;
            quit|esc) bye ;;
        esac
        printf '\e[%dA' "$n"
    done
    printf '\e[%dA\e[J' $(( n + 1 ))
    tput cnorm; [[ -t 0 ]] && stty echo
    CHECKED=""
    for i in "${!vals[@]}"; do [[ ${on[i]} == on ]] && CHECKED+="${vals[i]} "; done
    CHECKED=${CHECKED% }
    answered "$q" "${CHECKED:-none}"
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- Plugin browser -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# Left: the plugin checklist plus anything picked from the repository. Right (after "find from repository"):
# a live search over every ros-<distro>-* package in the ROS apt repository, names + descriptions.
PKG_INDEX="" PKG_INDEX_PID="" PKG_INDEX_DISTRO="" EXTRA_PKGS=() PKGS_ARG=""
declare -A INST_PKG=()

# build_pkg_index: name + description of every ros-<distro>-* package
#   in:  DISTRO, CODENAME; apt's copy of the ROS repo index, else packages.ros.org, else apt-cache search
#   out: stdout: "name<TAB>description" lines, sorted
build_pkg_index() {
    local arch list out
    arch=$(dpkg --print-architecture)
    list=/var/lib/apt/lists/packages.ros.org_ros2_ubuntu_dists_${CODENAME}_main_binary-${arch}_Packages
    out=$({ if [[ -r $list ]]; then cat "$list"
            else FETCH_TIMEOUT=60 fetch "http://packages.ros.org/ros2/ubuntu/dists/$CODENAME/main/binary-$arch/Packages.gz" | gzip -dc; fi
          } 2>/dev/null | awk -v pfx="ros-$DISTRO-" '
            index($0, "Package: ") == 1 { p = substr($0, 10); keep = index(p, pfx) == 1 && p !~ /-dbgsym$/; next }
            keep && index($0, "Description: ") == 1 { print p "\t" substr($0, 14); keep = 0 }' | sort -u -t$'\t' -k1,1)
    [[ -n $out ]] || out=$(apt-cache search --names-only "^ros-$DISTRO-" 2>/dev/null | grep -v -- '-dbgsym ' | sed 's/ - /\t/' | sort)
    [[ -n $out ]] && printf '%s\n' "$out"
}

# pkg_index_start: build the package index in the background (starts when the plugin step opens)
#   in:  DISTRO (a different distro than last time starts over)
#   out: PKG_INDEX (filled once ready), PKG_INDEX_PID, PKG_INDEX_DISTRO
pkg_index_start() {
    [[ -n $PKG_INDEX && $PKG_INDEX_DISTRO == "$DISTRO" ]] && return 0
    if [[ -n $PKG_INDEX ]]; then   # went back and picked another distro: start over
        kill "$PKG_INDEX_PID" 2>/dev/null; rm -f "$PKG_INDEX" "$PKG_INDEX.part"
    fi
    PKG_INDEX=$(mktemp) PKG_INDEX_DISTRO=$DISTRO
    { build_pkg_index >"$PKG_INDEX.part" && mv "$PKG_INDEX.part" "$PKG_INDEX"; } &
    PKG_INDEX_PID=$!
}

# load_installed_pkgs: which ros-<distro>-* packages are installed
#   in:  DISTRO
#   out: INST_PKG[name]=1
load_installed_pkgs() {
    local name state
    INST_PKG=()
    while read -r name state; do [[ $state == ii* ]] && INST_PKG[$name]=1; done \
        < <(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' "ros-$DISTRO-*" 2>/dev/null)
}

# search_index <query>: search the package index; every word must match, name matches first
#   in:  $1 query words; PKG_INDEX
#   out: stdout: matching index lines
search_index() {
    awk -F'\t' -v q="$1" '
        BEGIN { n = split(tolower(q), w, " ") }
        { l = tolower($0); for (i = 1; i <= n; i++) if (!index(l, w[i])) next
          if (n && index(tolower($1), w[1])) a[++na] = $0; else b[++nb] = $0 }
        END { for (i = 1; i <= na; i++) print a[i]; for (i = 1; i <= nb; i++) print b[i] }' "$PKG_INDEX"
}

# plugin_browser <title> <id> <description> <on|off|lock> ...: plugin checklist + live repository search
#   in:  $1 title, then id/description/state triples (lock = installed); EXTRA_PKGS (kept from a
#        visit before shift+tab), CAN_BACK
#   out: CHECKED, EXTRA_PKGS, the answer line(s) (a second "Packages" line adds 1 to choose's
#        "pending"); status 1 on shift+tab
plugin_browser() {
    local LC_ALL=C.UTF-8 title=$1; shift
    local ids=() descs=() st=() n i sel=0 focus=left right=0 q="" res=() rsel=0 roff=0 lofs=0 status=loading w=0 back=0
    local picks=() pdesc=() H B lw rw LK=() LI=() pfx="ros-$DISTRO-" name desc j
    while (( $# )); do ids+=("$1"); descs+=("$2"); st+=("$3"); shift 3; done
    n=${#ids[@]}
    for i in "${!ids[@]}"; do (( ${#ids[i]} > w )) && w=${#ids[i]}; done
    for i in "${!ids[@]}"; do [[ ${st[i]} != lock ]] && { sel=$i; break; }; done
    [[ ${st[sel]} == lock ]] && sel=$n   # everything installed: start on "find from repository"
    for name in "${EXTRA_PKGS[@]}"; do [[ $name == "$pfx"* ]] && { picks+=("$name"); pdesc+=(""); }; done   # kept from a visit before shift+tab
    load_installed_pkgs
    pkg_index_start
    COLS=$(tput cols); ROWS=$(tput lines)
    H=$(( ROWS - 1 < 24 ? ROWS - 1 : 24 )); B=$(( H - 2 ))
    printf '\n%.0s' $(seq 1 "$H"); printf '\e[%dA' "$H"
    REG_TOP=$(cursor_row); REG_TOP=${REG_TOP:-$(( ROWS - H ))}
    tput civis; [[ -t 0 ]] && stty -echo   # held keys must not echo between reads

    # browser_rows: the left list: plugins, the search entry, then repository picks
    #   in:  ids, picks
    #   out: LK (row kinds: mod | find | pick), LI (index into ids / picks)
    browser_rows() {
        LK=() LI=()
        for i in "${!ids[@]}"; do LK+=(mod); LI+=("$i"); done
        LK+=(find); LI+=(-1)
        for i in "${!picks[@]}"; do LK+=(pick); LI+=("$i"); done
    }
    # refilter: rerun the search for the current query
    #   in:  q, status (only once the index is ready)
    #   out: res, rsel=0, roff=0
    refilter() {
        [[ $status == ready ]] || return 0
        mapfile -t res < <(search_index "$q" | head -n 2000)
        rsel=0 roff=0
    }
    # selectable <row>: can the cursor rest on this left row? (not on installed plugins)
    #   in:  $1 row index into LK
    #   out: status 0 = selectable
    selectable() { [[ ${LK[$1]} == find || ${LK[$1]} == pick || ( ${LK[$1]} == mod && ${st[${LI[$1]}]} != lock ) ]]; }
    # descv <text> <width>: a dim description cut to a width
    #   in:  $1 text, $2 width
    #   out: FIT
    descv() { fitv "$1" $(( $2 > 1 ? $2 : 1 )); FIT="$C_DIM$FIT$C_RESET"; }   # cut the description alone, so it stays dim
    # toggle_pick <full name> <description>: add or remove a repository pick (installed ones can't be picked)
    #   in:  $1 package name, $2 description; INST_PKG
    #   out: picks, pdesc
    toggle_pick() {
        for j in "${!picks[@]}"; do
            if [[ ${picks[j]} == "$1" ]]; then picks=("${picks[@]:0:j}" "${picks[@]:j+1}"); pdesc=("${pdesc[@]:0:j}" "${pdesc[@]:j+1}"); return; fi
        done
        [[ -n ${INST_PKG[$1]} ]] && return
        picks+=("$1"); pdesc+=("$2")
    }
    # is_picked <full name>: is the package picked?
    #   in:  $1 package name
    #   out: status 0 = picked
    is_picked() { local x; for x in "${picks[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

    # browser_draw: draw the whole browser in one write
    #   in:  every local of plugin_browser (rows, focus, query, results, scroll offsets)
    #   out: the screen; lw, rw, lofs, roff
    browser_draw() {
        local out="" r line row k idx mark cur text rb hc
        lw=$(( right ? (COLS * 45 / 100) : COLS )); rw=$(( COLS - lw - 3 ))
        (( sel < lofs )) && lofs=$sel; (( sel >= lofs + B )) && lofs=$(( sel - B + 1 ))
        rb=$(( B - 2 ))
        (( rsel < roff )) && roff=$rsel; (( rsel >= roff + rb )) && roff=$(( rsel - rb + 1 ))

        hc=$C_CUR; [[ $focus == left ]] || hc=""   # the focused pane's header carries the accent
        printf -v line '\e[%d;1H\e[2K%s?%s %s%s%s' "$REG_TOP" "$C_CUR" "$C_RESET" "$C_BOLD$hc" "$title" "$C_RESET"; out+=$line
        for (( r = 0; r < B; r++ )); do
            row=$(( REG_TOP + 1 + r )); k=$(( lofs + r )); text=""
            if (( k < ${#LK[@]} )); then
                idx=${LI[k]}
                cur="  "; (( k == sel )) && cur="${C_CUR}❯${C_RESET} "
                case ${LK[k]} in
                    mod)  case ${st[idx]} in on) mark="${C_DONE}◉" ;; lock) mark="${C_DONE}✓" ;; *) mark="${C_TODO}○" ;; esac
                          descv "${descs[idx]}" $(( lw - w - 7 ))
                          printf -v text '%s%s%s %-*s  %s' "$cur" "$mark" "$C_RESET" "$w" "${ids[idx]}" "$FIT" ;;
                    find) printf -v text '%s%s⌕ find from repository…%s' "$cur" "$C_CUR" "$C_RESET" ;;
                    pick) name=${picks[idx]#"$pfx"}; descv "${pdesc[idx]}" $(( lw - ${#name} - 7 ))
                          printf -v text '%s%s◉%s %s  %s' "$cur" "$C_DONE" "$C_RESET" "$name" "$FIT" ;;
                esac
            fi
            fitv "$text" $(( lw - 1 ))
            printf -v line '\e[%d;1H\e[2K%s%s' "$row" "$FIT" "$C_RESET"; out+=$line
            (( right )) || continue
            text=""
            if (( r == 0 )); then
                printf -v text '%s⌕%s %s%s%s%s  %s%s%s' "$C_CUR" "$C_RESET" "$C_BOLD$([[ $focus == right ]] && echo "$C_CUR")" "$q" "$C_RESET" \
                    "$([[ $focus == right ]] && echo "${C_CUR}▏${C_RESET}")" "$C_DIM" \
                    "$(case $status in ready) echo "${#res[@]}$( (( ${#res[@]} == 2000 )) && echo +) matches · $pfx*" ;; loading) echo "$(spin_frame) loading package list…" ;; *) echo "package list unavailable (offline?)" ;; esac)" "$C_RESET"
            elif (( r == 1 )); then
                text="$([[ $focus == right ]] && echo "$C_CUR" || echo "$C_SEP")$(printf '─%.0s' $(seq 1 "$rw"))${C_RESET}"
            else
                k=$(( roff + r - 2 ))
                if (( k < ${#res[@]} )); then
                    name=${res[k]%%$'\t'*}; desc=${res[k]#*$'\t'}
                    cur="  "; (( k == rsel )) && cur="${C_CUR}❯${C_RESET} "
                    if [[ -n ${INST_PKG[$name]} ]]; then mark="${C_DONE}✓"; elif is_picked "$name"; then mark="${C_DONE}◉"; else mark="${C_TODO}○"; fi
                    name=${name#"$pfx"}; descv "$desc" $(( rw - ${#name} - 6 ))
                    printf -v text '%s%s%s %s  %s' "$cur" "$mark" "$C_RESET" "$name" "$FIT"
                fi
            fi
            fitv "$text" "$rw"
            printf -v line '\e[%d;%dH%s│%s %s%s' "$row" $(( lw + 1 )) "$C_SEP" "$C_RESET" "$FIT" "$C_RESET"; out+=$line
        done
        # key help sits under the focused pane and lists only that pane's keys
        if [[ $focus == right ]]; then keys TYPE search "↑/↓" move ENTER toggle TAB next ESC "close search"; fitv "$KEYS" "$rw"; k=$(( lw + 3 ))
        else keys "↑/↓" move ENTER toggle TAB next $( (( CAN_BACK )) && echo SHIFT+TAB back) A all Q quit; fitv "$KEYS" $(( lw - 1 )); k=1; fi
        printf -v line '\e[%d;1H\e[2K\e[%d;%dH%s%s' $(( REG_TOP + H - 1 )) $(( REG_TOP + H - 1 )) "$k" "$FIT" "$C_RESET"; out+=$line
        printf '%s' "$out"
    }

    while :; do
        browser_rows
        (( sel >= ${#LK[@]} )) && sel=$(( ${#LK[@]} - 1 ))
        read -t 0 || browser_draw   # keys still queued (a held arrow): handle them before paying for a redraw
        read_key "$([[ $status == loading ]] && echo 0.15)"
        if [[ $status == loading ]] && ! kill -0 "$PKG_INDEX_PID" 2>/dev/null; then
            [[ -s $PKG_INDEX ]] && status=ready || status=failed
            refilter
        fi
        [[ $KEY == none ]] && continue
        if [[ $focus == right ]]; then
            if [[ -n $CH ]]; then q+=$CH; refilter; continue; fi   # space just types: the search is multi-word
            case $KEY in
                up)        (( rsel > 0 )) && (( rsel-- )) ;;
                down)      (( rsel < ${#res[@]} - 1 )) && (( rsel++ )) ;;
                enter)     (( ${#res[@]} )) && toggle_pick "${res[rsel]%%$'\t'*}" "${res[rsel]#*$'\t'}" ;;
                backspace) q=${q%?}; refilter ;;
                clear)     q=""; refilter ;;
                esc)       right=0 focus=left ;;   # the query and results stay, so ⌕ reopens it as it was
                tab)       break ;;
            esac
            continue
        fi
        case $KEY in
            up)    for (( i = 0; i < ${#LK[@]}; i++ )); do sel=$(( (sel - 1 + ${#LK[@]}) % ${#LK[@]} )); selectable "$sel" && break; done ;;
            down)  for (( i = 0; i < ${#LK[@]}; i++ )); do sel=$(( (sel + 1) % ${#LK[@]} )); selectable "$sel" && break; done ;;
            enter)   # acts on the highlighted row, in both panes; tab / shift+tab leave the step
                case ${LK[sel]} in
                    find) right=1 focus=right ;;
                    mod)  case ${st[${LI[sel]}]} in on) st[${LI[sel]}]=off ;; off) st[${LI[sel]}]=on ;; esac ;;
                    pick) toggle_pick "${picks[${LI[sel]}]}" "" ;;
                esac ;;
            tab)     break ;;
            backtab) (( CAN_BACK )) && { back=1; break; } ;;
            all)   j=off; for i in "${!st[@]}"; do [[ ${st[i]} == off ]] && j=on; done
                   for i in "${!st[@]}"; do [[ ${st[i]} != lock ]] && st[i]=$j; done ;;
            quit|esc) printf '\e[%d;1H\e[J' "$REG_TOP"; bye ;;
        esac
    done

    printf '\e[%d;1H\e[J' "$REG_TOP"   # collapse into a one-line answer
    tput cnorm; [[ -t 0 ]] && stty echo
    CHECKED=""
    for i in "${!ids[@]}"; do [[ ${st[i]} == on ]] && CHECKED+="${ids[i]} "; done
    CHECKED=${CHECKED% }
    EXTRA_PKGS=("${picks[@]}")
    (( back )) && return 1   # choices are kept for when the step reopens
    answered "$title" "${CHECKED:-none}"
    if (( ${#picks[@]} )); then   # their own answer line (choose's "pending" counts it for shift+tab)
        answered "Packages" "$(join ", " "${picks[@]#"$pfx"}")"
        pending=$(( pending + 1 ))
    fi
    return 0
}

# confirm <question> <y|n>: yes/no question
#   in:  $1 question, $2 default answer
#   out: the answer line; status 0 = yes
confirm() {
    local q=$1 def=$2 ans
    printf '%s?%s %s%s%s %s(%s)%s ' "$C_CUR" "$C_RESET" "$C_BOLD" "$q" "$C_RESET" "$C_DIM" "$([[ $def == y ]] && echo Y/n || echo y/N)" "$C_RESET"
    while :; do
        read_key
        case $KEY in
            yes)   ans=y; break ;;
            no)    ans=n; break ;;
            enter) ans=$def; break ;;
            quit|esc) ans=n; break ;;
        esac
    done
    printf '\r\e[2K'
    answered "$q" "$([[ $ans == y ]] && echo Yes || echo No)"
    [[ $ans == y ]]
}

# interactive: may we ask questions? (no -y, and both stdin and stdout are terminals)
#   in:  ASSUME_YES
#   out: status 0 = yes
interactive() { (( ! ASSUME_YES )) && [[ -t 0 && -t 1 ]]; }

# choose: decide MODE, then fill DISTRO / ROS_TYPE / WITH with inline prompts where flags didn't
#   in:  the flags, INSTALLED, VALID_DISTROS, RECOMMENDED
#   out: MODE, TARGET, DISTRO, ROS_TYPE, WITH, EXTRA_PKGS (+ answer lines on screen)
choose() {
    local items=() others=() d m state step=mode shown=() pending=0 lines CAN_BACK=0   # CAN_BACK: an earlier prompt to return to
    local distro_arg=$DISTRO type_arg=$ROS_TYPE bashrc_arg=$ADD_BASHRC
    if (( ! ${#VALID_DISTROS[@]} )) && [[ -z $REMOVE ]]; then
        for d in $(printf '%s\n' "${!DISTRO_UBUNTU[@]}" | sort); do items+=("$(dname "$d") → $(ubuntu_names "${DISTRO_UBUNTU[$d]}")"); done
        die "No ROS 2 distro is built for $(ubuntu_name "$CODENAME") yet. Available: $(join "; " "${items[@]}")"
    fi
    for d in "${VALID_DISTROS[@]}"; do is_installed "$d" || others+=("$d"); done

    # Each answered prompt leaves one line (plus any notes printed with it, counted in "pending").
    # shift+tab erases the last answer and reopens that prompt.
    # answered_step <step>: record that a prompt was answered (and how many lines it left)
    #   in:  $1 step name; pending (extra note lines printed with it)
    #   out: shown, pending=0, CAN_BACK=1
    answered_step() { shown+=("$1:$(( 1 + pending ))"); pending=0; CAN_BACK=1; }
    # go_back: shift+tab: erase the last answer and reopen that prompt
    #   in:  shown, pending
    #   out: step (the prompt to reopen), CAN_BACK; its lines erased from the screen
    go_back() {
        local e
        (( pending )) && printf '\e[%dA\e[J' "$pending"; pending=0
        (( ${#shown[@]} )) || return 0   # nothing earlier: reopen the same prompt
        e=${shown[-1]}; unset 'shown[-1]'; CAN_BACK=${#shown[@]}
        printf '\e[%dA\e[J' "${e#*:}"; step=${e%%:*}
    }

    while :; do
        case $step in
            mode)   # 1. What are we doing? With ROS already here, offer what makes sense instead of reinstalling it.
                DISTRO=$distro_arg ROS_TYPE=$type_arg ADD_BASHRC=$bashrc_arg
                if [[ -n $REMOVE ]]; then
                    MODE=remove TARGET=$REMOVE
                elif (( ${#INSTALLED[@]} )); then
                    TARGET=$ROS_DISTRO; is_installed "$TARGET" || TARGET=${INSTALLED[0]}
                    if [[ -n $DISTRO ]]; then
                        if is_installed "$DISTRO"; then MODE=extras TARGET=$DISTRO; else MODE=parallel; fi
                    elif interactive; then
                        local tname alt=()
                        tname=$(dname "$TARGET")
                        for d in "${others[@]}"; do alt+=("$(dname "$d")"); done
                        items=("extras|plugins" "Add $tname plugins (Gazebo, Nav2, MoveIt, or anything from the ROS repository)")
                        (( ${#others[@]} )) && items+=(
                            replace  "Remove $tname, then install $(join " or " "${alt[@]}")"
                            parallel "Install $(join " or " "${alt[@]}") alongside $tname  ${C_ERR}⚠ not recommended${C_RESET}")
                        items+=(remove "Uninstall $tname" quit "Leave everything as it is")
                        pick "ROS 2 $tname is already installed. What now?" extras "${items[@]}" || { go_back; continue; }
                        answered_step mode
                        MODE=$PICK
                        [[ $MODE == quit ]] && bye
                    else
                        MODE=extras
                    fi
                else
                    MODE=fresh
                fi
                step=distro ;;

            distro)   # 2. Which distro?
                DISTRO=$distro_arg
                case $MODE in
                    remove)
                        is_installed "$TARGET" || die "ROS 2 $(dname "$TARGET") isn't installed"
                        DISTRO=$TARGET
                        if interactive; then confirm "Remove ROS 2 $(dname "$TARGET") (every ros-$TARGET-* package)?" n || bye; fi
                        return ;;
                    extras)
                        DISTRO=$TARGET ROS_TYPE=$(installed_type "$TARGET") ;;
                    parallel|replace)
                        (( ${#others[@]} )) || die "No other ROS 2 distro is built for $(ubuntu_name "$CODENAME")"
                        if [[ $MODE == parallel ]]; then
                            printf '%s!%s Parallel installs work, but each shell must source only one distro. %s\e]8;;%s\e\\%s\e]8;;\e\\%s\n' \
                                "$C_ERR" "$C_RESET" "$C_DIM" "https://www.reddit.com/r/ROS/comments/1iegfmz/comment/ma9avz5/" "Open Robotics on this" "$C_RESET"
                            (( pending++ ))
                        fi
                        if [[ -z $DISTRO ]] && interactive; then
                            distro_pick "Distro to install" || { go_back; continue; }
                            answered_step distro; DISTRO=$PICK
                        fi
                        DISTRO=${DISTRO:-${others[0]}} ;;
                    fresh)
                        if [[ -z $DISTRO ]] && interactive; then
                            distro_pick "ROS 2 distro" || { go_back; continue; }
                            answered_step distro; DISTRO=$PICK
                        fi
                        DISTRO=${DISTRO:-${RECOMMENDED:-${VALID_DISTROS[0]}}} ;;
                esac
                [[ -z $ROS_TYPE ]] && ROS_TYPE=$(detect_type)
                interactive || return 0
                step=type ;;

            type)   # 3. Type, then plugins (the rc file is asked about at the very end, once ROS is proven to work)
                if [[ $MODE != extras ]]; then
                    pick "Install type" "$ROS_TYPE" \
                        desktop  "Full desktop: RViz, rqt, demos" \
                        ros-base "Headless: robots, servers, Raspberry Pi" || { go_back; continue; }
                    answered_step type
                    ROS_TYPE=$PICK
                fi
                step=plugins ;;

            plugins)
                items=()
                for m in "${MODULES[@]}"; do
                    IFS='|' read -r M_ID M_NAME M_DESC _ <<<"$m"
                    if mod_installed "$M_ID"; then state=lock
                    elif [[ " $WITH " == *" $M_ID "* || ( $M_ID == devtools && $MODE != extras ) ]]; then state=on
                    else state=off; fi
                    items+=("$M_ID" "$M_DESC$([[ $state == lock ]] && echo "${C_DIM} · installed")" "$state")
                done
                plugin_browser "Plugins for $(dname "$DISTRO")" "${items[@]}" || { WITH=$CHECKED; go_back; continue; }
                answered_step plugins
                WITH=$CHECKED
                break ;;
        esac
    done
}

# confirm_start: "Install … now?" before anything changes
#   in:  MODE, DISTRO, ROS_TYPE, TARGET, WITH, EXTRA_PKGS
#   out: returns on yes; bye on no; nothing asked for -y / remove
confirm_start() {
    local n p what=""
    interactive && [[ $MODE != remove ]] || return 0
    n=$(wc -w <<<"$WITH") p=${#EXTRA_PKGS[@]}
    (( n )) && what+=" + $n plugin$( (( n != 1 )) && echo s)"
    (( p )) && what+=" + $p package$( (( p != 1 )) && echo s)"
    echo
    case $MODE in
        extras)  confirm "Install${what# +} for $(dname "$DISTRO") now?" y || bye ;;
        replace) confirm "Remove $(dname "$TARGET") and install ros-$DISTRO-$ROS_TYPE$what now?" y || bye ;;
        *)       confirm "Install ros-$DISTRO-$ROS_TYPE$what now?" y || bye ;;
    esac
}

# validate: check the choices against this machine and drop what is already installed
#   in:  DISTRO, ROS_TYPE, WITH, PKGS_ARG, EXTRA_PKGS, VALID_DISTROS
#   out: WITH and EXTRA_PKGS trimmed; dies on bad input; exit 0 when there is nothing left to install
validate() {
    local m keep=""
    [[ $MODE == remove ]] && return 0
    if [[ $MODE != extras && " ${VALID_DISTROS[*]} " != *" $DISTRO "* ]]; then
        case ${DISTRO_STATUS[$DISTRO]} in
            end-of-life) die "ROS 2 $(dname "$DISTRO") has been $(lifespan "$DISTRO"); its packages are no longer published" ;;
            "")          die "Unknown distro '$DISTRO' (for this Ubuntu: ${VALID_DISTROS[*]})" ;;
            *)           die "ROS 2 $(dname "$DISTRO") targets $(ubuntu_names "${DISTRO_UBUNTU[$DISTRO]}"); this machine runs $(ubuntu_name "$CODENAME")" ;;
        esac
    fi
    [[ $ROS_TYPE =~ ^(desktop|ros-base)$ ]] || die "Unknown install type '$ROS_TYPE' (desktop | base)"
    for m in $WITH; do
        mod_get "$m" || die "Unknown plugin '$m'"
        if mod_installed "$m"; then echo -e "  ${C_DIM}already installed: $m${C_RESET}"; else keep+=" $m"; fi
    done
    WITH=${keep# }
    for m in $PKGS_ARG; do   # accept ROS names (underscores), apt short names, or full apt names
        m=${m//_/-}; [[ $m == ros-* ]] || m="ros-$DISTRO-$m"
        EXTRA_PKGS+=("$m")
    done
    keep=()
    for m in $(printf '%s\n' "${EXTRA_PKGS[@]}" | sort -u); do
        if pkg_installed "$m"; then echo -e "  ${C_DIM}already installed: $m${C_RESET}"; else keep+=("$m"); fi
    done
    EXTRA_PKGS=("${keep[@]}")
    if [[ $MODE == extras && -z $WITH ]] && (( ! ${#EXTRA_PKGS[@]} )); then
        echo -e "\n${C_DONE}✓${C_RESET} Nothing new to install: ROS 2 $(dname "$DISTRO") already has everything selected.\n"
        exit 0
    fi
}

# plan: turn the choices into stages
#   in:  MODE, TARGET, DISTRO, ROS_TYPE, WITH, EXTRA_PKGS, DO_UPGRADE
#   out: STAGES (footer chips), STAGE_DESC (summary text), STEPS (functions to run)
plan() {
    local m
    STAGES=() STAGE_DESC=() STEPS=()
    # stage <chip name> <summary text> <step>: add one stage
    #   in:  $1 name, $2 description for the summary, $3 step command
    #   out: appends to STAGES, STAGE_DESC, STEPS
    stage() { STAGES+=("$1"); STAGE_DESC+=("$2"); STEPS+=("$3"); }   # stage <chip name> <summary text> <step>
    if [[ $MODE == remove || $MODE == replace ]]; then
        stage "Remove $(dname "$TARGET")" "" step_remove; stage Cleanup "" step_autoremove
        [[ $MODE == remove ]] && return
    fi
    needs_prepare && stage Prepare "prerequisites" step_prepare
    stage Sources "ROS 2 apt source" step_sources
    [[ $MODE == fresh ]] && (( DO_UPGRADE )) && stage Upgrade "system packages" step_upgrade
    [[ $MODE != extras ]] && stage "ROS 2" "$(dname "$DISTRO") · $ROS_TYPE" step_ros
    for m in "${MODULES[@]}"; do   # keep table order regardless of how --with was typed
        IFS='|' read -r M_ID M_NAME M_DESC _ <<<"$m"
        [[ " $WITH " == *" $M_ID "* ]] && stage "$M_NAME" "$M_DESC" "step_module $M_ID"
    done
    (( ${#EXTRA_PKGS[@]} )) && stage Packages "picked from the repository" step_packages
    [[ " $WITH " == *" devtools "* ]] && stage rosdep "" step_rosdep
}

# run_plan: run every stage in order
#   in:  STEPS, STAGES
#   out: STAGE_IDX, RUN_START; dies at the first stage that fails
run_plan() {
    local i
    for i in "${!STEPS[@]}"; do
        STAGE_IDX=$i TASK_PCT=0 RUN_START=${RUN_START:-$SECONDS}
        say_head "$i"
        ui_draw
        ${STEPS[i]} || die "${STAGES[i]} failed"
    done
    STAGE_IDX=${#STEPS[@]}
    task 100 "All done"
}

# sudo_keepalive: ask for the sudo password now, then keep it cached until we exit
#   in:  SUDO, DRY_RUN
#   out: a background refresher (sudo -n -v every 50 s); dies without sudo
sudo_keepalive() {
    [[ -n $SUDO ]] && (( ! DRY_RUN )) || return 0
    sudo -v || die "sudo is required"
    # output is hidden behind the footer, so a password prompt mid-install would be invisible
    # -v and no tty: with use_pty (Ubuntu's default) a running sudo relays the terminal's input and would
    # swallow keys and the cursor-position reply ui_init waits for
    ( while kill -0 $$ 2>/dev/null; do sudo -n -v; sleep 50; done ) </dev/null >/dev/null 2>&1 &
}

# ros_works: can a clean shell source this distro and run ros2?
#   in:  DISTRO, RC_SHELL
#   out: status 0 = works; REASON when it doesn't
ros_works() {
    local setup=/opt/ros/$DISTRO/setup.$RC_SHELL opt=()
    REASON=""
    [[ -f $setup ]] || { REASON="$setup is missing"; return 1; }
    [[ $RC_SHELL == zsh ]] && opt=(-f)   # skip the user's own zsh startup files
    env -i HOME="$HOME" PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM="$TERM" "$RC_SHELL" "${opt[@]}" -c \
        ". '$setup' >/dev/null 2>&1; [ \"\$ROS_DISTRO\" = '$DISTRO' ]" || { REASON="sourcing $setup fails"; return 1; }
    env -i HOME="$HOME" PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM="$TERM" "$RC_SHELL" "${opt[@]}" -c \
        ". '$setup' >/dev/null 2>&1; timeout 60 ros2 pkg prefix rclcpp" >/dev/null 2>&1 || { REASON="ros2 doesn't run after sourcing $setup"; return 1; }
}

# rerun_hint: how to run this again with the same options
#   in:  ORIG_ARGS, $0
#   out: stdout
rerun_hint() {
    local args=""
    (( ${#ORIG_ARGS[@]} )) && args=" $(printf '%q ' "${ORIG_ARGS[@]}")"
    if [[ -f $0 ]]; then printf 'bash %q%s' "$0" "${args% }"
    else printf 'the same command you started with%s' "${args:+ (options:${args% })}"; fi
}

# What ROS Manager adds to the rc file lives in one marked block, so it can be found, rewritten and removed.
# The two markers may be the same text: the awk below toggles, it never reopens a block on its end line.
RC_BEGIN="# ── ROSMan ──" RC_END="# ── ROSMan ──"
COLCON_HOOK=/usr/share/colcon_argcomplete/hook/colcon-argcomplete   # + .bash / .zsh, from ros-dev-tools

# rc_without_block <file>: the file minus our block (and the blank line above it)
#   in:  $1 rc file; RC_BEGIN, RC_END
#   out: stdout
rc_without_block() {
    awk -v b="$RC_BEGIN" -v e="$RC_END" '
        !s && index($0, b) == 1 { s = 1; held = 0; next }
        s                       { if (index($0, e) == 1) s = 0; next }
        held                    { print ""; held = 0 }
        /^$/                    { held = 1; next }
                                { print }
        END                     { if (held) print "" }' "$1" 2>/dev/null
}

# rc_block_body <file>: the commands inside our block
#   in:  $1 rc file; RC_BEGIN, RC_END
#   out: stdout: one command per line (comments left out)
rc_block_body() {
    awk -v b="$RC_BEGIN" -v e="$RC_END" 's && index($0, e) == 1 { s = 0; next } !s && index($0, b) == 1 { s = 1; next } s && !/^#/' "$1" 2>/dev/null
}

# rc_block <command...>: our block as it is written to the rc file
#   in:  the commands
#   out: stdout: blank line, begin marker, note, commands, end marker
rc_block() {
    local LC_ALL=C.UTF-8 rule; printf -v rule '─%.0s' {1..60}
    printf '\n%s%s\n' "$RC_BEGIN" "${rule:${#RC_BEGIN}}"
    printf '#    Added by ROS Manager. Running it again rewrites this block; put your own lines outside it.\n'
    printf '%s\n' "$@"
    printf '%s%s\n' "$RC_END" "${rule:${#RC_END}}"
}

# rc_write <file> <command...>: replace our block (no commands = remove it)
#   in:  $1 rc file, the rest are the commands
#   out: the file rewritten in place (keeps symlinks and permissions)
rc_write() {
    local f=$1 new; shift
    new=$(rc_without_block "$f"; (( $# )) && rc_block "$@")
    printf '%s\n' "$new" >"$f"
}

# rc_unsource <file> <distro>: stop an rc file sourcing a removed distro, in our block and in lines added by hand
#   in:  $1 rc file, $2 distro id; DRY_RUN (then it only reports)
#   out: the file edited, <file>.ros-manager.bak kept, restored if the result fails bash -n / zsh -n;
#        ok / warn lines (other mentions of the distro are only reported)
rc_unsource() {
    local f=$1 d=$2 old new body=() n chk=bash rc=${1/#$HOME/\~} l
    # "source /opt/ros/<d>/setup.bash", ". '/opt/ros/<d>/local_setup.zsh'  # ros", ...
    local re="^([[:space:]]*)(source|[.])[[:space:]]+[\"']?/opt/ros/$d/(local_)?setup[.](bash|zsh|sh)[\"']?[[:space:]]*;?[[:space:]]*(#.*)?\$"
    [[ -f $f ]] || return 0
    old=$(<"$f")
    if grep -q "^$RC_BEGIN" "$f"; then   # our block: drop the distro's line, keep the rest (colcon completion)
        mapfile -t body < <(rc_block_body "$f" | grep -Ev "$re")
        new=$(rc_without_block "$f"; (( ${#body[@]} )) && rc_block "${body[@]}")
    else
        new=$old
    fi
    # top-level lines go; indented ones (inside an if-block) become a no-op so the block stays valid
    new=$(awk -v re="$re" '$0 ~ re { if (match($0, /^[ \t]+/)) print substr($0, 1, RLENGTH) ": # removed by ROS Manager: " substr($0, RLENGTH + 1); next } { print }' <<<"$new")
    [[ $new == "$old" ]] && return 0
    n=$(diff <(printf '%s\n' "$old") <(printf '%s\n' "$new") | grep -c '^<')
    if (( DRY_RUN )); then ok "(dry run) would stop $rc sourcing $(dname "$d") ($n line$( (( n > 1 )) && echo s))"; return 0; fi

    [[ $f == *zshrc ]] && command -v zsh >/dev/null && chk=zsh
    cp -p "$f" "$f.ros-manager.bak" && printf '%s\n' "$new" >"$f" || { warn "Couldn't edit $rc; remove its /opt/ros/$d lines yourself"; return 0; }
    if ! "$chk" -n "$f" 2>/dev/null && "$chk" -n "$f.ros-manager.bak" 2>/dev/null; then   # never leave a broken rc behind
        cp -p "$f.ros-manager.bak" "$f"
        warn "Left $rc unchanged (the edit broke its syntax); remove its /opt/ros/$d lines yourself"; return 0
    fi
    ok "$rc no longer sources $(dname "$d") ${C_DIM}(backup: $rc.ros-manager.bak)${C_RESET}"
    while IFS= read -r l; do   # anything else (aliases, guarded one-liners) is the user's to judge
        warn "$rc line ${l%%:*} still mentions /opt/ros/$d: ${C_DIM}${l#*:}${C_RESET}"
    done < <(grep -n "/opt/ros/$d" "$f" | grep -v 'removed by ROS Manager')
}

# setup_rc: last step: prove ROS works, then (with the user's OK) add our block to their rc file
#   in:  DISTRO, RC_FILE, RC_SHELL, MODE, TARGET, WITH, ADD_BASHRC, DRY_RUN
#   out: RC_ADDED=1 when the rc sources this distro; if ros2 doesn't work it offers to rerun the install,
#        else prints the rerun command and exits 1
setup_rc() {
    local line="source /opt/ros/$DISTRO/setup.$RC_SHELL" rc=${RC_FILE/#$HOME/\~} def=y
    echo
    if (( DRY_RUN )); then
        echo -e "${C_DONE}✓${C_RESET} ${C_DIM}(dry run) would check that a fresh $RC_SHELL can source /opt/ros/$DISTRO/setup.$RC_SHELL and run ros2${C_RESET}"
    else
        until ros_works; do
            echo -e "${C_ERR}✗${C_RESET} ${C_BOLD}ROS 2 $(dname "$DISTRO") doesn't work yet:${C_RESET} $REASON"
            if interactive && confirm "Run the install steps again?" y; then
                plan; ui_init; run_plan; ui_end; echo
            else
                echo -e "  ${C_DIM}Log: $LOGFILE${C_RESET}"
                echo -e "  To fix it, run ROS Manager again: ${C_BOLD}$(rerun_hint)${C_RESET}\n"
                exit 1
            fi
        done
        echo -e "${C_DONE}✓${C_RESET} ${C_BOLD}Checked:${C_RESET} a fresh $RC_SHELL sources /opt/ros/$DISTRO/setup.$RC_SHELL and runs ros2"
    fi

    # what the user's own lines already do (anywhere, even inside their if-blocks) stays theirs
    local own body want=() what=() hook=$COLCON_HOOK.$RC_SHELL
    own=$(rc_without_block "$RC_FILE") body=$(rc_block_body "$RC_FILE")
    if grep -Eq "^[^#]*/opt/ros/$DISTRO/setup\.(bash|zsh|sh)" <<<"$own"; then
        echo -e "${C_DONE}✓${C_RESET} $rc already sources $(dname "$DISTRO")"; RC_ADDED=1
    else
        want+=("$line"); what+=("ROS 2 $(dname "$DISTRO")")
    fi
    if [[ -f $hook ]] || { (( DRY_RUN )) && [[ " $WITH " == *" devtools "* ]]; }; then
        if grep -q colcon-argcomplete <<<"$own"; then echo -e "${C_DONE}✓${C_RESET} $rc already has colcon tab completion"
        else want+=("source $hook"); what+=("colcon tab completion"); fi
    fi
    (( ${#want[@]} )) || return 0
    if [[ $body == "$(printf '%s\n' "${want[@]}")" ]]; then
        echo -e "${C_DONE}✓${C_RESET} $rc already has the ROS Manager block"; RC_ADDED=1; return 0
    fi
    (( ADD_BASHRC )) || return 0   # --no-rc
    if interactive; then
        if [[ $MODE == parallel ]]; then
            def=n; echo -e "${C_WARN}!${C_RESET} $rc already sources $(dname "$TARGET"); sourcing both in one shell clashes"
        fi
        confirm "Add $(join " + " "${what[@]}") to $rc?" "$def" || return 0
    elif [[ $MODE == parallel || $MODE == extras ]]; then   # unattended: only a new main install touches the rc file
        return 0
    fi
    if (( ! DRY_RUN )) && ! { rc_write "$RC_FILE" "${want[@]}" && [[ $(rc_block_body "$RC_FILE") == "$(printf '%s\n' "${want[@]}")" ]]; }; then
        echo -e "${C_ERR}✗${C_RESET} Couldn't write to $rc. Add these lines yourself:"
        printf "    ${C_BOLD}%s${C_RESET}\n" "${want[@]}"
        return 0
    fi
    [[ " ${want[*]} " == *" $line "* ]] && RC_ADDED=1
    echo -e "${C_DONE}✓${C_RESET} $( (( DRY_RUN )) && echo "(dry run) would add" || echo Added) to $rc:${C_DIM}"
    rc_block "${want[@]}" | sed '1d; s/^/    /'
    echo -n "$C_RESET"
}

# dep_mix <package...>: what a list of packages is made of
#   in:  package names
#   out: stdout: e.g. "120 ROS · 30 Python · 25 libraries · 9 system"
dep_mix() {
    local p ros=0 gz=0 py=0 lib=0 other=0 out=()
    for p; do
        case $p in
            ros-*)                                            (( ros++ )) ;;
            gz-*|libgz-*|ignition-*|libignition-*|*sdformat*) (( gz++ )) ;;
            python3-*)                                        (( py++ )) ;;
            lib*)                                             (( lib++ )) ;;
            *)                                                (( other++ )) ;;
        esac
    done
    (( ros ))   && out+=("$ros ROS")
    (( gz ))    && out+=("$gz Gazebo")
    (( py ))    && out+=("$py Python")
    (( lib ))   && out+=("$lib $(plural "$lib" library libraries)")
    (( other )) && out+=("$other system")
    join " · " "${out[@]}"
}

# plural <n> <one> <many>: the right word for a count
#   in:  $1 count, $2 singular, $3 plural
#   out: stdout
plural() { (( $1 == 1 )) && printf '%s' "$2" || printf '%s' "$3"; }

# human_kib <KiB>: a size for people
#   in:  $1 size in KiB
#   out: stdout: "820 kB" / "820 MB" / "1.4 GB"
human_kib() {
    if   (( $1 >= 1048576 )); then printf '%d.%d GB' $(( $1 / 1048576 )) $(( $1 % 1048576 * 10 / 1048576 ))
    elif (( $1 >= 1024 ));    then printf '%d MB' $(( $1 / 1024 ))
    else                           printf '%d kB' "$1"; fi
}

# summary: what the install put on the system, stage by stage: asked-for packages, then what came with them
#   in:  STAGES, STAGE_DESC, PKG_LOG, RUN_START, DRY_RUN
#   out: stdout: a tree per stage, then totals (new packages, disk space, time)
summary() {
    local i j p t kib leaves=() req=() new=() up=() deps=() all=()
    [[ -s $PKG_LOG ]] || return 0
    for i in "${!STAGES[@]}"; do
        mapfile -t req < <(awk -v s="$i" '$1 == s && $2 == "R" { print $3 }' "$PKG_LOG")
        mapfile -t new < <(awk -v s="$i" '$1 == s && $2 == "N" { print $3 }' "$PKG_LOG")
        mapfile -t up  < <(awk -v s="$i" '$1 == s && $2 == "U" { print $3 }' "$PKG_LOG")
        (( ${#req[@]} + ${#new[@]} + ${#up[@]} )) || continue
        all+=("${new[@]}") leaves=() deps=()
        for p in "${new[@]}"; do [[ " ${req[*]} " == *" $p "* ]] || deps+=("$p"); done
        for p in "${req[@]}"; do
            if (( DRY_RUN ));                     then leaves+=("$p ${C_DIM}· dry run")
            elif [[ " ${new[*]} " == *" $p "* ]]; then leaves+=("${C_DONE}$p")
            else                                       leaves+=("$p ${C_DIM}· already installed"); fi
        done
        (( ${#up[@]} ))   && leaves+=("${#up[@]} upgraded ${C_DIM}· $(dep_mix "${up[@]}")")
        (( ${#deps[@]} )) && leaves+=("${C_DIM}+ ${#deps[@]} $(plural ${#deps[@]} dependency dependencies) · $(dep_mix "${deps[@]}")")
        echo -e "\n  ${C_DONE}✓${C_RESET} ${C_BOLD}${STAGES[i]}${C_RESET}${STAGE_DESC[i]:+  ${C_DIM}${STAGE_DESC[i]}${C_RESET}}"
        for j in "${!leaves[@]}"; do
            t="├─"; (( j == ${#leaves[@]} - 1 )) && t="└─"
            echo -e "    ${C_SEP}${t}${C_RESET} ${leaves[j]}${C_RESET}"
        done
    done
    (( ${#all[@]} )) || { echo; return 0; }
    kib=$(dpkg-query -W -f='${Installed-Size}\n' "${all[@]}" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
    t=$(( SECONDS - ${RUN_START:-$SECONDS} ))
    echo -e "\n  ${C_CUR}${#all[@]}${C_RESET} new packages · ${C_CUR}$(human_kib "$kib")${C_RESET} on disk · ${C_CUR}$(( t / 60 ))m $(( t % 60 ))s${C_RESET}\n"
}

# finish: the end screen: result, summary, log path, rc file, how to try it
#   in:  MODE, DISTRO, TARGET, ROS_TYPE, RC_SHELL
#   out: stdout
finish() {
    local line="source /opt/ros/$DISTRO/setup.$RC_SHELL"
    ui_end clear   # the step list has done its job: the summary replaces it
    if [[ $MODE == remove ]]; then
        echo -e "\n${C_DONE}${C_BOLD}✓ ROS 2 $(dname "$TARGET") removed.${C_RESET}\n"
        return
    fi
    case $MODE in
        extras)  echo -e "\n${C_DONE}${C_BOLD}✓ Plugins installed for ROS 2 $(dname "$DISTRO").${C_RESET}" ;;
        replace) echo -e "\n${C_DONE}${C_BOLD}✓ Replaced $(dname "$TARGET") with ROS 2 $(dname "$DISTRO") ($ROS_TYPE).${C_RESET}" ;;
        *)       echo -e "\n${C_DONE}${C_BOLD}✓ ROS 2 $(dname "$DISTRO") ($ROS_TYPE) is ready.${C_RESET}" ;;
    esac
    summary
    echo -e "  Log ${C_DIM}$LOGFILE${C_RESET}"
    setup_rc   # the very last question, and only once ROS is proven to work
    if (( RC_ADDED )); then
        echo -e "\n  Try it in a new terminal:  ${C_BOLD}ros2 run demo_nodes_cpp talker${C_RESET}"
        echo -e "  ${C_DIM}(or in this one: $line)${C_RESET}"
    else
        echo -e "\n  Try it:  ${C_BOLD}$line && ros2 run demo_nodes_cpp talker${C_RESET}"
    fi
    [[ $MODE == parallel ]] && echo -e "  ${C_DIM}Your shells still source $(dname "$TARGET") by default; open a fresh terminal before sourcing $(dname "$DISTRO").${C_RESET}"
    echo -e "\n  Thank you ${C_DONE}$(whoami)${C_RESET}! Issues and ideas: ${C_DIM}github.com/koustavbetal/ros_manager${C_RESET}\n"
}

# cleanup: EXIT trap: stop background jobs, remove temp files, hand the terminal back usable
#   in:  the *_PID / temp file globals
#   out: none
cleanup() {
    ui_end
    [[ -n $DISCOVERY_PID ]] && kill "$DISCOVERY_PID" 2>/dev/null
    [[ -n $DISCOVERY_FILE ]] && rm -rf "$DISCOVERY_FILE" "$DISCOVERY_TMP"
    [[ -n $PKG_INDEX_PID ]] && kill "$PKG_INDEX_PID" 2>/dev/null
    [[ -n $PKG_INDEX ]] && rm -f "$PKG_INDEX" "$PKG_INDEX.part"
    [[ -n $PKG_LOG ]] && rm -f "$PKG_LOG"
    [[ -t 0 ]] && stty echo 2>/dev/null
    [[ -t 1 ]] && tput cnorm
}

#-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=- main -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-#
# main <args...>: the whole run: flags, splash, questions, plan, install, finish
#   in:  the script's arguments
#   out: exit status: 0 done / nothing to do, 1 failed
main() {
    ORIG_ARGS=("$@")
    parse_args "$@"
    [[ $ID == ubuntu ]] || die "ROS Manager only supports Ubuntu (found: $ID)"
    mkdir -p "$LOG_DIR" && : >"$LOGFILE"
    trap cleanup EXIT
    trap 'die "Interrupted by $(whoami)"' INT TERM

    discover_start        # network lookup runs while the splash is already on screen
    detect_installed
    splash
    discover_finish
    choose
    validate
    plan
    confirm_start
    sudo_keepalive
    ui_init
    run_plan
    finish
}

# run only when executed (also via `bash <(curl ...)`), not when sourced by progress_demo.bash
[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
