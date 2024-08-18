#!/usr/bin/env bash

# ./deploy.sh  [-r gitrepo] [-t tag] [-a app_tags]
# app_tags format is dept:product:env:service like ops:ptrwebsite:prod:websiteui
# ./deploy.sh [-c config.yaml] --it takes all info from config file
# leave tag empty if you want to use latest

# Ensure the AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Please install it to proceed."
    exit 1
fi

# Ensure the yq is installed
if ! command -v yq &> /dev/null; then
    echo "yq command not found. Please install it to proceed."
    exit 1
fi

# Check for required arguments
if [ $# -le 1 ]; then
    echo "Usage:./deploy.sh [-c config.yaml] --it takes all info from config file"
    echo "Usage:./deploy.sh  [-r gitrepo] [-t tag] [-a app_tags]"
    exit 1
fi

# Parse options using getopt

TEMP=$(getopt -o c:r:t:a: --long config:,repo:,tag:,apptags: -n 'deploy.sh' -- "$@")
if [ $? != 0 ]; then
    echo "Terminating..." >&2
    exit 1
fi

# Note the quotes around `$TEMP`: they are essential!
eval set -- "$TEMP"


# Initialize default values
configfile=""
AppkubeDepartment=""
AppkubeProduct=""
AppkubeEnvironment=""
AppkubeService=""
repo=""
git_tag=""
app_tags=""
rebuildstack=""
organization=""
domain=""
subdomain=""
hostedzoneid=""

declare -A awsprofiles
awsprofiles[promodeagro]="promode"
awsprofiles[ptrtechnology]="ptr"


## parse the arguments 
while true; do
    case "$1" in
        -c | --config )
            configfile=$2; shift 2; break;;
        -r | --repo )
           repo=$2; shift 2;;
        -t | --tag )
           git_tag=$2; shift 2;;
        -a | --apptags )
           app_tags=$2; shift 2;;
        -- )
            shift; break ;;
        * )
            break ;;
    esac
done


if [ -n $configfile ]; then
    echo "using configs from config file"
    # Read the YAML file using yq
    AppkubeDepartment=$(yq eval '.apptags.department' $configfile)
    AppkubeProduct=$(yq eval '.apptags.product' $configfile)
    AppkubeEnvironment=$(yq eval '.apptags.environment' $configfile)
    AppkubeService=$(yq eval '.apptags.service' $configfile) 
    repo=$(yq eval '.git.repo' $configfile)
    git_tag=$(yq eval '.git.tag' $configfile)
    rebuildstack=$(yq eval '.general.rebuild-stack' $configfile)
    organization=$(yq eval '.general.organization' $configfile)

else
    ## parse App app_tags
    AppkubeDepartment=$(echo "${app_tags}" | awk -F ':' '{print $1}')
    AppkubeProduct=$(echo "${app_tags}" | awk -F ':' '{print $2}')
    AppkubeEnvironment=$(echo "${app_tags}" | awk -F ':' '{print $3}')
    AppkubeService=$(echo "${app_tags}" | awk -F ':' '{print $4}')
fi

deployService() {
    export SERVERLESS_ACCESS_KEY=AKex5MakC16gyLLEOWIqY8TxMKERFjjM9kweCQFoL6f8o
    echo "deleting existing checkout folder"
    clean-checkout-folder 2>/dev/null>&1
    echo "cloning the source to checkout folder"
    git clone "$1" checkout
    echo "Starting to deploy the services"
    awsprofile=$(eval getAwsProfile "$organization")
    echo "Obtained awsprofile $awsprofile"   
    deployCmd='serverless deploy --param=''"'department=$2'"'' --param=''"'product=$3'"'' --param=''"'service=$4'"'' --aws-profile '$awsprofile''
    pushd checkout && serverless plugin install -n serverless-offline && $deployCmd && pushd +1   
}

getAwsProfile() {
    echo "${awsprofiles[$1]}"
#     ${sounds[dog]}
#   if [[ "$1" == "promodeagro" ]]; then
#     apro
#   else
#     aptr
# fi
}
## clean the checkout folder
clean-checkout-folder() {
    echo "deleting checkout folder"
    rm -rf checkout
}

check-existing-stack() {
    aws cloudformation list-stacks --no-paginate --output json --stack-status-filter "CREATE_COMPLETE" "UPDATE_COMPLETE" "ROLLBACK_COMPLETE" "ROLLBACK_FAILED" "DELETE_FAILED" --query 'StackSummaries[*].StackName' | grep $1 > /dev/null
    if [ $? -eq 0 ]; then
        true
    else
        false
    fi
}

# function to delete the existing stack if user requests so
delete-existing-stack() {
        # existing=$(check-existing-stack $1)
        # echo "existing variable value : $existing "
        echo "entering existing stack delete section"
        if check-existing-stack "$1"; then
            echo "stack exist with the name: "$1""
            echo "deleting the stack"
            clean-existing-buckets "$1" 
            delete-stack "$1"
            keep-waiting-until-stack-deleted "$1"
        else
            echo "stack does not exist with the name: $1"
        fi
}

rebuild-stack() {
  if [[ "$rebuildstack" == "true" ]]; then
    true
  else
    false
fi
}

# Function to delete the stack
delete-stack() {
    aws cloudformation delete-stack --stack-name $1 --output text 2>/dev/null
    iferror "Delete Stack Api faile for some unknown reason"
}

# Function to check the stack status
check_stack_status() {
    aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null
}
# Function that check delete status and wait upto deletion
keep-waiting-until-stack-deleted(){
    echo "Waiting for CloudFormation stack '$1' to be deleted..."
    # Loop until the stack is deleted
    while true; do
        STATUS=$(check_stack_status)

        if [ $? -ne 0 ]; then
            # If describe-stacks fails, it likely means the stack has been deleted
            echo "CloudFormation stack '$1' has been successfully deleted."
            break
        elif [ "$STATUS" == "DELETE_FAILED" ]; then
            echo "CloudFormation stack deletion failed. Please check the AWS CloudFormation console for more details."
            exit 1
        else
            echo "Stack status: $STATUS. Waiting for deletion to complete..."
        fi
        # Wait for a while before checking again
        sleep 10
    done
}

updatecmdb() {
    aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output json > output.json
    aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
}

iferror() {
    if [ $? -ne 0 ]; then
        echo "$1"
        exit 1
    fi
}

echo "configfile: $configfile"
echo "repo getting deployed: $repo"
echo "git tag : $git_tag"
echo "AppkubeDepartment Value: $AppkubeDepartment"
echo "AppkubeProduct Value: $AppkubeProduct"
echo "AppkubeEnvironment Value: $AppkubeEnvironment"
echo "AppkubeService Value: $AppkubeService"
echo "Remaining arguments: $@"

STACK_NAME="$AppkubeDepartment-$AppkubeProduct-$AppkubeService-$AppkubeEnvironment"

# awsprofile=$(eval getAwsProfile "promodeagro")
# echo "Obtained awsprofile $awsprofile"

if rebuild-stack;then
    delete-existing-stack "$STACK_NAME"
fi
deployService "$repo" "$AppkubeDepartment" "$AppkubeProduct" "$AppkubeService" 
clean-checkout-folder
updatecmdb "$STACK_NAME"
