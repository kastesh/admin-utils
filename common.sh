export LANG=en_US.UTF-8
export NOLOCALE=yes
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin

[[ -z $DEBUG ]] && DEBUG=0
LOG_DIR=$HOME/logs
[[ ! -d $LOG_DIR ]] && mkdir -p $LOG_DIR

TMP_DIR=/tmp
[[ -d /dev/shm  ]] && TMP_DIR=/dev/shm

OS_VERSION=$(cat /etc/redhat-release 2>&1 | \
    sed -e "s/CentOS Linux release//;s/CentOS release // " | cut -d'.' -f1 | \
    sed -e "s/\s\+//g")

setColoredText() {
    colorOff='\033[0m'       # Text Reset
    # Regular Colors
    colorBlack='\033[0;30m'        # Black
    colorRed='\033[0;31m'          # Red
    colorGreen='\033[0;32m'        # Green
    colorYellow='\033[0;33m'       # Yellow
    colorBlue='\033[0;34m'         # Blue
    colorPurple='\033[0;35m'       # Purple
    colorCyan='\033[0;36m'         # Cyan
    colorWhite='\033[0;37m'        # White]]]]]]]]]'

    colorDefault="$Green"   
    isColoredText=1
}

log(){
    msg="${1}"
    type="${2:-0}"

    case $type in
        "1") NOTICE=WARN
             colorDefault="$colorYellow"
             ;;
        "2") NOTICE=CRIT
             colorDefault="$colorRed"
             ;;
        "3") NOTICE=INFO
             ;;
         *)  NOTICE=DEBUG
             colorDefault="$colorPurple"
             ;;
    esac

    [[ $isColoredText -gt 0 ]] && echo -ne "$colorDefault"
    [[ $DEBUG -gt 0 ]] && \
        printf "%-16s: %4s: [%d]> %s\n" \
        "$(date +%Y/%m/%dT%H:%M)" "$NOTICE" "$$" "$msg"
    [[ $isColoredText -gt 0 ]] && echo -ne "$colorOff"

    [[ -n $LOG ]] && \
        printf "%-16s: %4s: [%d]> %s\n" "$(date +%Y/%m/%dT%H:%M)" \
        "$NOTICE" "$$" "$msg"  >> $LOG

}
debug() {
    [[ $DEBUG -eq 0 ]] && return 0
    log "${1}" 4
}
warn(){
    log "${1}" 1
}

info(){
    log "${1}" 3
}

exitAndClean() {
    # remove temporary file
    if [[ -n $TMP_FILE && -f $TMP_FILE  ]]; then
        if [[ $DEBUG -gt 0 ]]; then
            log "Tmporary data is sav in: $TMP_FILE"
        else
            rm -f $TMP_FILE
        fi
    fi

    # clear lock if exists
    clear_lock

    exit $1
}

error() {
    msg="${1}"
    exit="${2:-1}"

    log "$msg" 2

    [[ $exit -gt 0 ]] && \
        exitAndClean $exit
}

set_lock(){
    [[ -f $LOCK ]] && \
        error "There is lock file=$LOCK. Exit." 1
    touch $LOCK || \
        error "Cannot create lock file=$LOCK. Exit."
}

clear_lock(){
    [[ -n $LOCK && -f $LOCK ]] && \
        rm -f $LOCK
}

createTmpFile(){
    TMP_FILE=$(mktemp $TMP_DIR/${FUNCNAME[0]}.XXXXXX)
}


# aws wrappers
# return ZoneId by ZoneName
getZoneId() {
    local zone="${1}"
    local region="${2:-eu-central-1}"
    [[ -z $zone ]] && \
        error "${FUNCNAME[0]}: The option zone cannot be empty. Exit."

    ZONE_ID=

    debug "${FUNCNAME[0]}: Process zone=$zone region=$region"
    
    createTmpFile

    # aws request
    aws route53 list-hosted-zones-by-name \
        --dns-name $ZONE \
        --query 'HostedZones[0].[Id,Name]' \
        --output text \
        > $TMP_FILE 2>&1
    aws_rtn=$?
    [[ $aws_rtn -gt 0 ]] && \
        error "${FUNCNAME[0]}: An error occurred while executing the aws cmd.$(head -n1 $TMP_FILE)" 1

    firstLine=$(head -n1 $TMP_FILE)
    zoneId=$(echo "$firstLine" | awk '{print $1}' | \
        sed -e "s|/hostedzone/||g")
    zoneName=$(echo "$firstLine" | awk '{print $2}')
    if [[ $zoneName == "${zone}" || $zoneName == "${zone}." ]]; then
        ZONE_ID=$zoneId
        return 0
    fi
    return 1
}
