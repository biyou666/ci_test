set -e

sudo rm -rf ./log
rm -rf ./.fail
mkdir -p /artifacts/log

MAX_RETRIES=3
TOTAL_NAMES=""
SUITE_TIMEOUT=20m
BLACKLIST_FLAG="-b python_udf_library"

OS=$(uname)
ARCH=$(uname -m)

# Set args for run.sh script
input="$1"
if [[ -z "$input" ]]; then
    echo "Smoke test executed by default"
fi
echo "$input"
IFS=";" read -ra features <<< "$input"

for feature in "${features[@]}"; do
    if [[ "$feature" == "hybrid" ]]; then
        AGGREGATION_CHECK_MODE=random
        OVERRIDE_FLAG="-f ./deployment/docker-compose-p3k1.override.yaml"
        echo "Smoke test executed in hybrid mode"
    elif [[ "$feature" == "python-udf-library" ]]; then
        BLACKLIST_FLAG=""
        echo "Smoke test scope contains: python-udf-library"
    else
        echo "Error: Invalid parameter '$feature'. support: [hybrid;python-udf-library]"
        break
    fi
done

if [ "$CI" == "true" ]; then
    export SSH_USER=ubuntu
    export SSH_DIR=/home/ubuntu/.ssh
fi

echo "CI:${CI}"
echo "AGGREGATION_CHECK_MODE:${AGGREGATION_CHECK_MODE}"
echo "OVERRIDE_FLAG:${OVERRIDE_FLAG}"

# prepare ssh keys
bash ./ssh.sh init
echo "run.sh SSH_DIR:${SSH_DIR}"

# get all names and concatenate them into a string
for folder in $(find "./smoke" -mindepth 1 -maxdepth 1 -type d ! -name "deployment"); do
    config_file="$folder/config.yaml"
    if [ -f "$config_file" ]; then
        name=$(awk '/^name:/ {print $2}' "$config_file")
        TOTAL_NAMES="$TOTAL_NAMES$name,"
    fi
done

set +e

echo "$TOTAL_NAMES" > temp.lock

# use 5 clusters to run the smoke tests
for INDEX in {1..5}; do
{
    ENV_VARIABLE="${GROUPS_ARRAY[$INDEX-1]%,}"
    export ENV_VARIABLE=$ENV_VARIABLE
    export CONTAINER_NAME_PREFIX=$INDEX
    export DOCKER_PROJECT="smoke_p3k1_$INDEX"
    

    LOG_DIR=./log/p3k1/"$INDEX"_log
    mkdir -p $LOG_DIR
    
    while true; do
        (
        flock -x 7 7>&7 
        
        TOTAL_NAMES=$(cat temp.lock)
        # no task in the queue
        if [ -z "$TOTAL_NAMES" ]; then
            echo "1" > should_break.txt
        else
            echo "0" > should_break.txt
            SUITE_NAME=$(echo $TOTAL_NAMES | cut -d ',' -f 1)
            echo "$SUITE_NAME" > "$INDEX"_suite_name.txt
            TOTAL_NAMES=$(echo $TOTAL_NAMES | cut -d ',' -f 2-)
            
            echo "$TOTAL_NAMES" > temp.lock
        fi
        
        )7<>temp.lock

        SHOULD_BREAK=$(cat should_break.txt)
        if [ "$SHOULD_BREAK" -eq "1" ]; then
            echo "no task in queue, cancel new docker-compose"
            break
        fi

        SUITE_NAME=$(cat "$INDEX"_suite_name.txt)
        PROFFIEL_FLAG=""
        if [ "$SUITE_NAME" == "dictionary" ]; then
            PROFFIEL_FLAG="--profile source"
        fi
        docker-compose -f ./deployment/docker-compose-p3k1.yaml $PROFFIEL_FLAG $OVERRIDE_FLAG -p "smoke_p3k1_$INDEX" up -d
        sleep 15
        docker ps

        # get the suite name and run the smoke test
        mkdir -p "$LOG_DIR"/"$SUITE_NAME"
        echo "Group $INDEX, Suite $SUITE_NAME: begin"
        echo "Execute command: docker exec ${INDEX}_p3k1_probe timeout ${SUITE_TIMEOUT} probe smoke -v /smoke -d /deploy/smoke -c p3k1 -s ${SUITE_NAME} --os ${OS} --arch ${ARCH} --variable CONTAINER_NAME_PREFIX=${CONTAINER_NAME_PREFIX} --variable aggregation_check_mode=${AGGREGATION_CHECK_MODE} ${BLACKLIST_FLAG} --retry ${MAX_RETRIES} -f /log/probe.log"
        docker exec ${INDEX}_p3k1_probe timeout ${SUITE_TIMEOUT} probe smoke -v /smoke -d /deploy/smoke -c p3k1 -s ${SUITE_NAME} --os ${OS} --arch ${ARCH} --variable CONTAINER_NAME_PREFIX=${CONTAINER_NAME_PREFIX} --variable aggregation_check_mode=${AGGREGATION_CHECK_MODE} ${BLACKLIST_FLAG} --retry ${MAX_RETRIES} -f /log/probe.log
        echo "Group $INDEX, Suite $SUITE_NAME: end"

        # print && collect timeplusd log
        # save fatal logs under ./log/p3k1/ directory with name '<suite_name>_timeplusd-server.fatal.log'
        CONTAINER_NAMES=$(docker ps -a --format '{{.Names}}' | grep ${INDEX}_timeplus)
        FATAL_LOG_PATTERN='<Fatal>'
        WARN_ERR_LOG_PATTERN='<Error>|<Warning>'
        for NAME in $CONTAINER_NAMES; do
            FULL_LOG=./log/p3k1/${INDEX}_log/timeplusd-server.log
            FATAL_LOG=/artifacts/log/${SUITE_NAME}_timeplusd-server.fatal.log
            ERROR_WARN_LOG=/artifacts/log/${SUITE_NAME}_timeplusd-server.warn.log
            docker cp ${NAME}:/var/log/timeplusd-server/timeplusd-server.log $FULL_LOG
            ## collect fatal log and upload to artifacts
            if sudo grep -q "$FATAL_LOG_PATTERN" "$FULL_LOG"; then
                echo "Fatal suite: $SUITE_NAME" >> ./.fail
                echo "------------[$SUITE_NAME] Logs from container $NAME (Fatal only)------------" | tee -a ./.fatal $FATAL_LOG  > /dev/null
                sudo grep -iE "$FATAL_LOG_PATTERN" "$FULL_LOG" | sudo tee -a ./.fatal $FATAL_LOG > /dev/null
                echo "----------------------------------------------------------------------------" | tee -a ./.fatal $FATAL_LOG  > /dev/null
            fi
            ## collect error and warn log and upload to artifacts
            sudo echo "------------[$SUITE_NAME] Logs from container $NAME (Error and Warn only)------------" | tee -a $ERROR_WARN_LOG  > /dev/null
            sudo grep -iE "$WARN_ERR_LOG_PATTERN" "$FULL_LOG" | tee -a $ERROR_WARN_LOG > /dev/null
            sudo echo "-------------------------------------------------------------------------------------" | tee -a $ERROR_WARN_LOG  > /dev/null
            sudo rm -rf $FULL_LOG
        done

        # print && collect probe log
        grep -r "Gatherer" "$LOG_DIR"/probe.log >> ./log/summary.log

        if [ ! -f "$LOG_DIR"/.status ]; then
            # no .status means the probe encounters with a panic or probe timeout
            echo "Group $INDEX, Suite $SUITE_NAME: Failed with panic or timeout" >> ./.fail
            echo "Group $INDEX, Suite $SUITE_NAME: Failed with panic or timeout"
            echo "Panic Log:"
        elif grep -q "succeed" "$LOG_DIR"/.status; then
            cp "$LOG_DIR"/probe.log "$LOG_DIR"/"$SUITE_NAME"/succeed.log
            echo "Group $INDEX, Suite $SUITE_NAME: Succeeded"
            echo "Succeed Log:"
        elif [ ! -f "$LOG_DIR/.wrong" ]; then
            cp "$LOG_DIR"/probe.log "$LOG_DIR"/"$SUITE_NAME"/fail_without_wrong_case.log
            echo "Group $INDEX, Suite $SUITE_NAME: Fail with no wrong cases found, it's caused by unrelated setup or teardown"
            echo "Log:"
        else
            line=$(head -n 1 "$LOG_DIR"/.wrong)
            cp "$LOG_DIR"/probe.log "$LOG_DIR"/"$SUITE_NAME"/fail.log
            echo "Group $INDEX, Suite $SUITE_NAME: Failed after $MAX_RETRIES retries" >> ./.fail
            echo "Failed cases: $line" >> ./.fail

            echo "Group $INDEX, Suite $SUITE_NAME: Failed after $MAX_RETRIES retries"
            echo "Group $INDEX, Suite $SUITE_NAME Failed cases: $line"
            echo "Fail Log:"
        fi
        
        cat "$LOG_DIR"/probe.log

        docker-compose -f ./deployment/docker-compose-p3k1.yaml $OVERRIDE_FLAG -p "smoke_p3k1_$INDEX" down -v

        sleep 5
    done
    
    
}&
done

wait 

aws s3 cp --no-progress --recursive ./log s3://tp-internal/proton/cluster/enterprise

bash ./ssh.sh clean

# print disk usage after test
df -lh

# print all the summary logs
cat ./log/summary.log

echo "====================Smoke Testing Result Summary===================="
# check if any test failed
if [ -f ./.fatal ]; then
    cat ./.fatal >> ./.fail
    rm -f ./.fatal
fi

if [ -f ./.fail ]; then
    echo "Some tests failed"  | tee -a $GITHUB_STEP_SUMMARY

    fail_output=$(cat ./.fail)
    if [ ${#fail_output} -gt 900 ]; then
        cat ./.fail
        cat ./.fail | head -c 900 >> $GITHUB_STEP_SUMMARY
        echo "-" >> $GITHUB_STEP_SUMMARY
        echo "### Output is too large, truncated to 900 bytes." >> $GITHUB_STEP_SUMMARY
    else
        echo "$fail_output" | tee -a $GITHUB_STEP_SUMMARY
    fi
else
    echo "All tests succeeded"  | tee -a $GITHUB_STEP_SUMMARY
fi
echo "====================Smoke Testing Result Summary===================="

echo "====================Smoke Testing Fatal Log========================="
find ./log/p3k1 -type f -name "*.fatal.log" -exec cat {} +
echo "====================Smoke Testing Fatal Log========================="

if [ -f ./.fail ]; then
    rm -f ./.fail
    exit 1
fi
