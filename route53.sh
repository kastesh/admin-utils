#!/bin/bash

PROGNAME=$(basename $0)
PROGPATH=$(dirname $0)
export HOME=/root

. $PROGPATH/common.sh || exit 4
setColoredText

printUsage(){
    exitCode=${1}

    echo "Usage: $PROGNAME -c|-d -z DOMAINNAME -t TOKEN -r RECORD"
    echo "Options:"
    echo " -h - show help message"
    echo " -v - enable debug mode"
    echo " -c - create txt record in the DOMAIN"
    echo " -d - delete txt record in the DOMAIN"
    echo " -t - TOKEN value"
    echo " -r - RECORD name"
    echo " -R - EC2 region name (default: eu-central-1)"
    echo 

    exit $exitCode
}
getChangeStatus(){
    id="${1}"

    TMP_FILE=$(mktemp $TMP_DIR/change_status.XXXXXX)
    aws route53 get-change \
        --id $reqId \
        --query ChangeInfo.Status > $TMP_FILE 2>&1
    aws_rtn=$?
    if [[ $? -gt 0 ]]; then
        error "An error occurred while executing the aws command."
    fi
    STATUSID=$(cat $TMP_FILE | sed -e "s/^\"//;s/\"$//")
    rm -f $TMP_FILE
}

getRequestStatus(){
    local statusfile="${1}"

    reqId=$(cat $statusfile | grep '"Id"' | \
        awk -F'"' '{print $4}')
    if [[ -z $reqId ]]; then
        warn "There is no Change Id in file=$statusfile"
        cat $statusfile
        return 0
    fi
    STATUSID=UNKNOWN
    while [[ $STATUSID != "INSYNC" ]]; do
        log "Get current status for change ID=$reqId; Current=$STATUSID"
        getChangeStatus "$reqId"
        sleep 10
    done
    rm -f $statusfile
}


createTXTRecord() {
    local record="${1}"
    local tokens="${2}"
    local zone_id="${3}"
    local region="${4}"
    
    CHANGES="{
    \"Changes\": [
    {
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
    \"Name\": \"$record\",
    \"ResourceRecords\": ["

    VALUES=
    for token in $(echo "$tokens" | \
        sed -e "s/,/ /g"); do
        [[ -n $VALUES ]] && VALUES="$VALUES,"
        VALUES="$VALUES{\"Value\":\"\\\"$token\\\"\"}"
    done
    CHANGES=$CHANGES"$VALUES"
    CHANGES=$CHANGES"],
    \"TTL\": 60,
    \"Type\": \"TXT\"
    }}],
    \"Comment\": \"Create $record in $zone_id at $(date +%Y-%d-%mT%H:%M:%S)\"}"

    TMP_FILE=$(mktemp $TMP_DIR/change_record_set_XXXXXX.json)
    echo "$CHANGES" | python -m json.tool > $TMP_FILE
    if [[ $? -gt 0 ]]; then
        echo "$CHANGES"
        error "File=$TMP_FILE doesn't contain json."
    fi

    log "Create record $record with value=$tokens; type=TXT"
    JSON_FILE=$TMP_DIR/change_record_set.json
    mv $TMP_FILE $JSON_FILE
    aws route53 change-resource-record-sets \
        --hosted-zone-id $zone_id \
        --change-batch "file:///$JSON_FILE" \
        > $TMP_FILE 2>&1
    aws_rtn=$?
    rm -f $JSON_FILE
    if [[ $aws_rtn -gt 0 ]]; then
        cat $TMP_FILE
        error "An error occurred while executing the aws command."
    fi
    getRequestStatus $TMP_FILE
    log "Create record=$record with value=$tokens"

}
processDNSLines(){
    local vals="${1}"
    local specs="${2}"
    local geo="${3}"
    if [[ -z $vals || -z $specs ]]; then
        warn "Incorrect call for processDNSLines; vals=$vals and specs=$specs"
        return 0

    fi

    name=$(echo "$specs" | awk '{print $2}')
    if [[ -n $geo ]]; then
        type=$(echo "$specs" | awk '{print $5}')
        ttl=$(echo "$specs" | awk '{print $4}')
    else
        type=$(echo "$specs" | awk '{print $4}')
        ttl=$(echo "$specs" | awk '{print $3}')
    fi
    if [[ -z $VALUES ]]; then
        VALUES="$name;$type;$ttl;$recordVals"
    else
        VALUES="$VALUES\n$name;$type;$ttl;$recordVals"
    fi
}

getAllRecords(){
    local zone_id="${1}"
    local next_token="${2}"

    MAX_ITEMS=20
    NEXT=""
    if [[ -n $next_token ]]; then
        NEXT="--starting-token $next_token"
    fi
    
    TMP_FILE=$(mktemp $TMP_DIR/list_records.XXXXXX)
    aws route53 list-resource-record-sets \
        --hosted-zone-id $zone_id \
        --max-items $MAX_ITEMS \
        --output text \
        $NEXT > $TMP_FILE 2>&1
    aws_rtn=$?
    if [[ $? -gt 0 ]]; then
        error "An error occurred while executing the aws command."
    fi
    NEXT_TOKEN=$(cat $TMP_FILE | grep '^NEXTTOKEN' | \
        awk '{print $2}')
    
    IFS_BAK=$IFS
    IFS=$'\n'
    isOneRecord=0
    local recordSpec=
    local recordVals=
    local recordGeo=
    for line in $(cat $TMP_FILE); do
        if [[ $(echo "$line" | grep "^RESOURCERECORDSETS" -c) -gt 0 ]]; then

            debug "recordSpec=$recordSpec; recordVals=$recordVals"
            processDNSLines "$recordVals" "$recordSpec" "$recordGeo"
            recordVals=
            recordGeo=
            recordSpec="$line"
        fi

        if [[ $(echo "$line" | grep "^GEOLOCATION" -c) -gt 0 ]]; then
            recordGeo="$(echo "$line" | awk '{print $2}')"
        fi

        if [[ $(echo "$line" | grep "^RESOURCERECORDS\s\+" -c) -gt 0 ]]; then
            val=$(echo "$line" | awk '{print $2}'| sed -e "s/^\"//;s/\"$//")
            if [[ -z $recordVals ]]; then
                recordVals="$val"
            else
                recordVals="$recordVals,$val"
            fi
        fi
    done
    rm -f $TMP_FILE
    processDNSLines "$recordVals" "$recordSpec" "$recordGeo"
    IFS=$IFS_BAK
    log "Next token=$NEXT_TOKEN"
}

deleteRecord() {
    local zone_id="${1}"
    local record="${2}"
    local record_type="${3}"
    local ttl="${4}"
    local values="${5}"

    CHANGES="{ \"Comment\": \"Delete $record at $(date +%Y-%m-%dT%H:%M:%S)\",\"Changes\": [
{\"Action\": \"DELETE\", \"ResourceRecordSet\":
{\"Name\": \"$record\",
\"Type\": \"${record_type^^}\",
\"TTL\": $ttl,
\"ResourceRecords\":["
    DELETES=
    for v in $(echo "$values" | \
        sed -e "s/,/ /g"); do
        [[ -n $DELETES ]] && DELETES="$DELETES,"
        DELETES="$DELETES{\"Value\":\"\\\"$v\\\"\"}"
    done
    CHANGES=$CHANGES"$DELETES"
    CHANGES=$CHANGES"]}}]}"

    TMP_FILE=$(mktemp $TMP_DIR/change_record_set_XXXXXX.json)
    echo "$CHANGES" | python -m json.tool > $TMP_FILE
    if [[ $? -gt 0 ]]; then
        echo "$CHANGES"
        error "File=$TMP_FILE doesn't contain json."
    fi

    JSON_FILE=$TMP_DIR/change_record_set.json
    mv $TMP_FILE $JSON_FILE
    aws route53 change-resource-record-sets \
        --hosted-zone-id $zone_id \
        --change-batch "file:///$JSON_FILE" \
        > $TMP_FILE 2>&1
    aws_rtn=$?
    rm -f $JSON_FILE
    if [[ $aws_rtn -gt 0 ]]; then
        error "An error occurred while executing the aws command."
    fi
    getRequestStatus $TMP_FILE
    log "Delete  record=$record with value=$values"
    return 0
}

findRecord(){
    local zone_id="${1}"
    local record="${2}"
    local record_type="${3:-txt}"

    record_type=${record_type^^}
    # gel all records
    VALUES=
    NEXT_TOKEN=
    getAllRecords "$zone_id"
    while [[ -n $NEXT_TOKEN ]]; do
        getAllRecords "$zone_id" $NEXT_TOKEN
    done

    IFS_BAK=$IFS
    IFS=$'\n'
    RECORD_VALS=
    for line in $(echo -e "$VALUES"); do
        name=$(echo "$line" | awk -F';' '{print $1}')
        type=$(echo "$line" | awk -F';' '{print $2}')
        ttl=$(echo "$line" | awk -F';' '{print $3}')

        if [[ ( $name == "${record}" || $name == "${record}." ) && \
            $type == "$record_type" ]]; then
            RECORD_VALS="${line}"
        fi

    done
    log "RECORD_VALS=$RECORD_VALS"
    IFS=$IFS_BAK
}

updateRecord(){
    local zone=${1}
    local record=${2}
    local value=${3}

    getZoneId $zone || \
        error "There is no zone=$zone"
    debug "zoneId=$ZONE_ID"

    findRecord "$ZONE_ID" "$record" "txt"
    if [[ -n $RECORD_VALS ]]; then
        name=$(echo "$RECORD_VALS" | awk -F';' '{print $1}')
        rtype=$(echo "$RECORD_VALS" | awk -F';' '{print $2}')
        ttl=$(echo "$RECORD_VALS" | awk -F';' '{print $3}')
        curr=$(echo "$RECORD_VALS" | awk -F';' '{print $4}')
        log " Process \"$ZONE_ID\" \"$name\" \"$rtype\" \"$ttl\" \"$curr\""

        deleteRecord "$ZONE_ID" "$name" "$rtype" "$ttl" "$curr"

        value="$value,$curr"

        debug "There are some values in $record; $value. Save it."
    fi

    createTXTRecord "$record" "$value" "$ZONE_ID"
}

deleteAllRecordValue(){
    local zone=${1}
    local record=${2}

    getZoneId $zone || \
        error "There is no zone=$zone"
    debug "zoneId=$ZONE_ID"

    findRecord "$ZONE_ID" "$record" "txt"
    if [[ -z $RECORD_VALS ]]; then
        log "There is no record=$record"
        return 0
    fi
    
    name=$(echo "$RECORD_VALS" | awk -F';' '{print $1}')
    rtype=$(echo "$RECORD_VALS" | awk -F';' '{print $2}')
    ttl=$(echo "$RECORD_VALS" | awk -F';' '{print $3}')
    curr=$(echo "$RECORD_VALS" | awk -F';' '{print $4}')
    log " Process \"$ZONE_ID\" \"$name\" \"$rtype\" \"$ttl\" \"$curr\""

    deleteRecord "$ZONE_ID" "$name" "$rtype" "$ttl" "$curr"
}

CREATE=0
DELETE=0
RECORD="_acme-challenge"
REGION="eu-central-1"
while getopts ":z:t:r:R:cdvh" opt; do
    case $opt in
        "h") printUsage 0 ;;
        "v") DEBUG=1 ;;
        "c") CREATE=1 ;;
        "d") DELETE=1 ;;
        "z") ZONE=$OPTARG ;;
        "t") TOKEN=$OPTARG ;;
        "r") RECORD=$OPTARG ;;
        \?) printUsage 1 ;;
    esac
done

# test options
[[ $CREATE -eq 1 && $DELETE -eq 1 ]] && \
    printUsage 1
[[ $CREATE -eq 0 && $DELETE -eq 0 ]] && \
    printUsage 1
[[ -z $ZONE ]] && \
    printUsage 1
[[ $CREATE -gt 0 && -z $TOKEN ]] && \
    printUsage 1

DNS=$RECORD.$ZONE
if [[ $(echo "$DNS" | grep -c "\.$") -gt 0 ]]; then
    DNS="${DNS}."
fi

if [[ $CREATE -gt 0 ]]; then
    updateRecord "$ZONE" "$DNS" "$TOKEN"
fi

if [[ $DELETE -gt 0 ]]; then
    deleteAllRecordValue "$ZONE" "$DNS"
fi
