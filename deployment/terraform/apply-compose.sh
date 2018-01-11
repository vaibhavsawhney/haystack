#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

#########################
# The command line help #
#########################
function display_help() {
    echo "Usage: $0 [option...] " >&2
    echo
    echo "   -a, --action               defines the action for deploying haystack components. possible values: install|uninstall, default: install"
    echo "   -u, --unit-name            applies the action on a deployable unit by its name, possible values: all|<component-name>, default: all (use separate -u for each unit)"
    echo "                              for example '-u zk -u kafka-service -u haystack-pipes-json-transformer' to start only the latter and the services on which it depends"
    echo "   -c, --cluster-type         choose the cluster-type settings for cluster. possible values: aws and local, default: local"
    echo "   -t, --tfvars-file-path     values which need to be passed to terraform in a tfvars file(required for aws deployment) eg : s3_bucket_name, aws_vpc_id, default:cluster/aws|local/variables.tfvars "
    echo "   -b, --backend-file-path     values which need to be passed to terraform s3 backend in a tfvars file(required for aws deployment) eg : bucket, region, default:cluster/aws|local/backend.tfvars "
    echo "   -s, --skip-approval         skips interactive approval of deployment plan before applying,default = false"


    echo
    # echo some stuff here for the -a or --add-options 
    exit 1
}

while :
do
    case "$1" in
      -c | --cluster-type)
          if [ $# -ne 0 ]; then
            CLUSTER_TYPE="$2"
          fi
          shift 2
          ;;
      -a | --action)
          if [ $# -ne 0 ]; then
            ACTION="$2"
          fi
          shift 2
          ;;
       -b | --backend-file-path)
          if [ $# -ne 0 ]; then
            BACKEND_VARS_FILE="$2"
          fi
          shift 2
          ;;
       -t | --tfvars-file-path)
          if [ $# -ne 0 ]; then
            TF_VARS_FILE="$2"
          fi
          shift 2
          ;;
       -s | --skip-approval)
          if [ $# -ne 0 ]; then
            SKIP_APPROVAL="$2"
          fi
          shift 2
          ;;      
      -h | --help)
          display_help  # Call your function
          exit 0
          ;;
      --) # End of all options
          shift
          break
          ;;
      -*)
          echo "Error: Unknown option: $1" >&2
          ## or call function display_help
          exit 1 
          ;;
      *)  # No more options
          break
          ;;
    esac
done

function verifyArgs() {
 if [[ -z $ACTION ]]; then
   ACTION=install
 fi
  if [[ -z $CLUSTER_TYPE ]]; then
   CLUSTER_TYPE=local
 fi
 if [[ -z $TF_VARS_FILE ]]; then
   TF_VARS_FILE=cluster/$CLUSTER_TYPE/variables.tfvars
 fi
 if [[ -z $BACKEND_VARS_FILE ]]; then
   BACKEND_VARS_FILE=cluster/$CLUSTER_TYPE/backend.tfvars
 fi
}

function setThirdPartySoftwareBasePath() {
 case "$(uname -s)" in
    Darwin)
      THIRD_PARTY_SOFTWARE_PATH=$DIR/third_party_softwares/mac/x64  
      ;;
    Linux)
      THIRD_PARTY_SOFTWARE_PATH=$DIR/third_party_softwares/linux/x64   
      ;;
 esac
}


function downloadThirdPartySoftwares() {

 setThirdPartySoftwareBasePath
 # variable for accessing third party softwares
 TERRAFORM=$THIRD_PARTY_SOFTWARE_PATH/terraform
 KUBECTL=$THIRD_PARTY_SOFTWARE_PATH/kubectl
 KOPS=$THIRD_PARTY_SOFTWARE_PATH/kops

 if [ ! -f $TERRAFORM ]|| [ ! -f $KUBECTL ]|| [ ! -f $KOPS ]; then
   $DIR/install-third-party-softwares.sh
 fi
}

function command_exists () {
    type "$1" &> /dev/null ;
}


function applyActionOnComponents() {
    case "$ACTION" in
       install)
          installComponents
          echo "Congratulations! you've successfully created haystack infrastructure"
          ;;
       uninstall)
          uninstallComponents
          echo "Congratulations! you've successfully destroyed haystack infrastructure"
          ;;
       *)
          echo "Error!!! Fail to understand the action type, see the help."
          display_help
          exit 1
          ;;
    esac
}

function uninstallComponents() {
 if [ "$SKIP_APPROVAL" = "true" ];then
   FORCE_FLAG="-force"
   else
    echo "$SKIP_APPROVAL"
 fi
    echo "Deleting haystack infrastructure using terraform"
   $TERRAFORM init -backend-config=$BACKEND_VARS_FILE cluster/$CLUSTER_TYPE

   #setting the correct kubectl config for terraform
   if [ "$CLUSTER_TYPE" = "aws" ];then
       #setting the correct kubectl config for terraform
        CLUSTER_NAME=$(echo "var.haystack_cluster_name" | $TERRAFORM console -var-file=$TF_VARS_FILE cluster/$CLUSTER_TYPE )
        AWS_DOMAIN_NAME=$(echo "var.aws_domain_name" | $TERRAFORM console -var-file=$TF_VARS_FILE cluster/$CLUSTER_TYPE )
        S3_BUCKET_NAME=$(echo "var.s3_bucket_name" | $TERRAFORM console -var-file=$TF_VARS_FILE cluster/$CLUSTER_TYPE )
        echo "setting kubectl context : $CLUSTER_NAME-k8s-$AWS_DOMAIN_NAME"
        $KOPS export --name $CLUSTER_NAME-k8s-$AWS_DOMAIN_NAME  --state s3://$S3_BUCKET_NAME
    fi

   $TERRAFORM destroy $FORCE_FLAG -var-file=$TF_VARS_FILE -var kubectl_executable_name=$KUBECTL -var kops_executable_name=$KOPS  cluster/$CLUSTER_TYPE
}

function installComponents() {
    if [ "$SKIP_APPROVAL" = "true" ];then
        AUTO_APPROVE="-auto-approve"
        else
        echo "$SKIP_APPROVAL"
    fi

    echo "Creating haystack infrastructure using terraform"

    $TERRAFORM init -backend-config=$BACKEND_VARS_FILE cluster/$CLUSTER_TYPE

    #setting the correct kubectl config for terraform
    if [ "$CLUSTER_TYPE" = "aws" ];then
        CLUSTER_NAME=$(echo "var.haystack_cluster_name" | $TERRAFORM console -var-file=$TF_VARS_FILE cluster/$CLUSTER_TYPE )
        AWS_DOMAIN_NAME=$(echo "var.aws_domain_name" | $TERRAFORM console -var-file=$TF_VARS_FILE cluster/$CLUSTER_TYPE )
        echo "setting kubectl context : $CLUSTER_NAME-k8s.$AWS_DOMAIN_NAME"
        $KUBECTL config set-context $CLUSTER_NAME-k8s.$AWS_DOMAIN_NAME
    fi

    $TERRAFORM apply $AUTO_APPROVE -var-file=$TF_VARS_FILE -var kubectl_executable_name=$KUBECTL -var kops_executable_name=$KOPS  cluster/$CLUSTER_TYPE
}


function verifyK8sCluster() {
  if [[ $CLUSTER_TYPE == 'local' ]]; then
    if command_exists minikube; then
        `minikube status > /tmp/minikube_status`
        if grep -q -i 'Running' /tmp/minikube_status; then
            echo "Congratulations! Minikube is found in running state!"
        else
             echo 'Minikube is not running, starting now...'
             minikube start
          fi
          rm -rf /tmp/minikube_status
    else
        echo "Minikube is not installed on local box, please setup minikube by following the instructions at https://kubernetes.io/docs/getting-started-guides/minikube"
        exit 1
    fi
  fi
}

# sanitize the arguments passed to the script, and set the defaults correctly
verifyArgs

#verify minikube is running in local mode
verifyK8sCluster

# download third party softwares like kubectl, gomplate, jq etc.
downloadThirdPartySoftwares

# install/delete the haystack components
applyActionOnComponents