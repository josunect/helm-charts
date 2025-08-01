#!/bin/bash
#
# This will ensure both the operator and server helm charts of a potential release can successfully install their respective apps.
#
# In order to run this script, you need access to a Kubernetes cluster. If one is not currently available, an attempt to start
# a KinD cluster will be made.
#
# Because this is a merely a smoke test, Istio is not required to be installed. The Kiali Operator and Server will not be tested
# for functionality. The only tests performed by this script will simply ensure the pods can start successfully and the images
# that were pulled are the expected ones.
#

set -ue

# where this script is located
SCRIPT_DIR="$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)"

# customizable settings via cmd line opts
CLIENT_EXE="$(which kubectl)"
GIT_REMOTE_NAME="origin"
GIT_LOCAL_DIR="${SCRIPT_DIR}/.."
HELM_EXE="$(which helm)"
KIND_EXE="$(which kind)"
RELEASE_BRANCH=""
RELEASE_BRANCH_PATTERN="helm-charts-release-*"

# this is the local branch we will create that tracks the remote release branch
SMOKETEST_BRANCH="smoketest"

# these are the namespaces where the operator and server will be installed
OPERATOR_NAMESPACE="smoketest-kiali-operator"
SERVER_NAMESPACE="smoketest-kiali-server"

# when set, this is the original git branch we switched from - we'll want to restore this branch when we exit
ORIGINAL_BRANCH=""

# this will be set if we needed to start our own KinD cluster to perform the test
KIND_CLUSTER_NAME=""

infomsg() {
  echo "[HACK] $1"
}

restore_env() {
  # Go back to the branch the user originally had checked out and delete the smoketest branch we created earlier
  if [ -n "${ORIGINAL_BRANCH}" ]; then
    infomsg "Restoring original git branch"
    git checkout ${ORIGINAL_BRANCH}
    if git rev-parse --verify ${SMOKETEST_BRANCH} &> /dev/null; then
      if ! git branch -D ${SMOKETEST_BRANCH} &> /dev/null; then
        infomsg "The test branch [${SMOKETEST_BRANCH}] is no longer needed but could not be deleted. Ignoring this error."
      fi
    fi
  fi

  # If we created a KinD cluster to do the test, delete it since we do not need it anymore.
  # Otherwise, delete the namespaces from the existing cluster.
  if [ -n "${KIND_CLUSTER_NAME}" ]; then
    infomsg "Deleting the KinD cluster"
    ${KIND_EXE} delete cluster --name ${KIND_CLUSTER_NAME}
  else
    if ${CLIENT_EXE} get namespace ${OPERATOR_NAMESPACE} &> /dev/null; then
      infomsg "Deleting the operator namespace used for the test"
      ${CLIENT_EXE} delete namespace ${OPERATOR_NAMESPACE}
    fi
    if ${CLIENT_EXE} get namespace ${SERVER_NAMESPACE} &> /dev/null; then
      infomsg "Deleting the server namespace used for the test"
      ${CLIENT_EXE} delete namespace ${SERVER_NAMESPACE}
    fi
  fi
}

abort_now() {
  infomsg "[ERROR] $1"
  restore_env
  exit 1
}

helpmsg() {
  cat <<HELP
This script will smoke test a release branch to ensure the helm charts can install the operator and server successfully.
Options:
-c|--client
    The client executable to use to access the Kubernetes cluster.
    Default: "${CLIENT_EXE}"
-gld|--git-local-dir
    The root directory where the local helm charts repo is found.
    Default: "${GIT_LOCAL_DIR}"
-grn|--git-remote-name
    If a --release-branch was not specified, an attempt to determine the latest release branch will be made by
    examining the branches found in this git remote whose branch names start with "${RELEASE_BRANCH_PATTERN}".
    Note that this script will perform a fetch of this remote repo in order to obtain the latest repo content.
    Default: "${GIT_REMOTE_NAME}"
-helm|--helm
    The helm executable to use when smoke testing the helm charts.
    Default: "${HELM_EXE}"
-k|--kind
    If a KinD cluster is needed for this test, this is the "kind" executable to be used.
    Default: "${KIND_EXE}"
-rb|--release-branch
    The remote release branch that has the helm charts to be tested.
    It will be assumed this branch exists in the --git-remote-name repo.
    This is typically the branch associated with the release PR that is generated by the release workflow.
    If this is left empty, an attempt to determine the latest release branch will be made.
    Default: "${RELEASE_BRANCH}"
-rbp|--release-branch-pattern
    This is the pattern all release branch names must follow. This is only used when --release-branch is not
    specified which requires this script to try to discovery the latest release branch in the git remote repo.
    Default: "${RELEASE_BRANCH_PATTERN}"
HELP
}

# process command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -c|--client)                     CLIENT_EXE="$2";               shift;shift; ;;
    -gld|--git-local-dir)            GIT_LOCAL_DIR="$2";            shift;shift; ;;
    -grn|--git-remote-name)          GIT_REMOTE_NAME="$2";          shift;shift; ;;
    -helm|--helm)                    HELM_EXE="$2";                 shift;shift; ;;
    -k|--kind)                       KIND_EXE="$2";                 shift;shift; ;;
    -rb|--release-branch)            RELEASE_BRANCH="$2";           shift;shift; ;;
    -rbp|--release-branch-pattern)   RELEASE_BRANCH_PATTERN="$2";   shift;shift; ;;
    -h|--help)                       helpmsg;                       exit 1       ;;
    *) echo "Unknown argument: [$key]. Aborting."; helpmsg; exit 1 ;;
  esac
done

infomsg "===SETTINGS===
CLIENT_EXE=$CLIENT_EXE
GIT_LOCAL_DIR=$GIT_LOCAL_DIR
GIT_REMOTE_NAME=$GIT_REMOTE_NAME
HELM_EXE=$HELM_EXE
KIND_EXE=$KIND_EXE
RELEASE_BRANCH=$RELEASE_BRANCH
RELEASE_BRANCH_PATTERN=$RELEASE_BRANCH_PATTERN"

if ! which ${CLIENT_EXE} &> /dev/null; then
  abort_now "The Kubernetes client executable is invalid: ${CLIENT_EXE}"
fi

if ! which ${HELM_EXE} &> /dev/null; then
  abort_now "The Helm executable is invalid: ${HELM_EXE}"
fi

if [ ! -d "${GIT_LOCAL_DIR}" ]; then
  abort_now "The local helm chart repo directory is invalid: ${GIT_LOCAL_DIR}"
fi

# Make sure we are in the correct directory. There must be a "docs" directory which is where the helm charts are stored.
cd "${GIT_LOCAL_DIR}"
infomsg "Working in directory: $(pwd)"
if ! ls docs &> /dev/null; then
  abort_now "You must run this script with a current working directory of the root directory of the Kiali helm charts repository."
fi

# Determine the latest release branch that needs to be tested - we will prepend the git remote to the front of the branch name here
infomsg "Fetching latest content from git remote [${GIT_REMOTE_NAME}]"
git fetch "${GIT_REMOTE_NAME}"
if [ -z "${RELEASE_BRANCH}" ]; then
  RELEASE_BRANCH="$(git branch -r --list "${GIT_REMOTE_NAME}/${RELEASE_BRANCH_PATTERN}" | sort | tail -n1 | tr -d ' ')"
  if [ -z "${RELEASE_BRANCH}" ]; then
    abort_now "Cannot find any branches that match [${GIT_REMOTE_NAME}/${RELEASE_BRANCH_PATTERN}] - there is nothing to test."
  fi
else
  RELEASE_BRANCH="${GIT_REMOTE_NAME}/${RELEASE_BRANCH}"
fi
infomsg "Will smoke test remote release branch [${RELEASE_BRANCH}]"

# Determine what branch we are currently on so we can be nice and take the user back to it after we are done with the smoke test.
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if ! git checkout -b ${SMOKETEST_BRANCH} ${RELEASE_BRANCH}; then
  abort_now "Failed to checkout the release branch. Make sure [${RELEASE_BRANCH}] is a valid remote branch name."
fi

# Determine the version we are going to smoke test
OPERATOR_VERSION="$(ls -1 docs/kiali-operator-*.tgz | sort -V | tail -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
SERVER_VERSION="$(ls -1 docs/kiali-server-*.tgz | sort -V | tail -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"

if [ "${OPERATOR_VERSION}" != "${SERVER_VERSION}" ]; then
  abort_now "The latest helm chart versions for operator [${OPERATOR_VERSION}] and server [${SERVER_VERSION}] do not match. Aborting the test."
fi

# Make sure we have access to a running k8s cluster. If there is none, try to start KinD.
if ! ${CLIENT_EXE} get ns &> /dev/null; then
  infomsg "There does not appear to be a Kubernetes cluster available. Attempting to start KinD..."
  if ! which ${KIND_EXE} &> /dev/null; then
    abort_now "The KinD executable is invalid: ${KIND_EXE}"
  fi
  KIND_CLUSTER_NAME="smoketest"
  if ! ${KIND_EXE} create cluster --name ${KIND_CLUSTER_NAME}; then
    abort_now "Failed to create a KinD cluster. Aborting smoke test."
  fi
fi

# SMOKE TESTING THE OPERATOR

infomsg "Smoke testing operator version [${OPERATOR_VERSION}]"

if ! ${HELM_EXE} install --create-namespace --namespace ${OPERATOR_NAMESPACE} kiali-operator docs/kiali-operator-${OPERATOR_VERSION}.tgz; then
  abort_now "The Operator Helm Chart did not install successfully. The smoke test has FAILED!"
fi

ACTUAL_OPERATOR_IMAGE="$(${CLIENT_EXE} get deployments -n ${OPERATOR_NAMESPACE} -l app.kubernetes.io/name=kiali-operator -o 'jsonpath={.items..spec.containers[0].image}{"\n"}')"
EXPECTED_OPERATOR_IMAGE="quay.io/kiali/kiali-operator:v${OPERATOR_VERSION}"
if [ "${ACTUAL_OPERATOR_IMAGE}" != "${EXPECTED_OPERATOR_IMAGE}" ]; then
  abort_now "The actual operator image [${ACTUAL_OPERATOR_IMAGE}] is not the expected image [${EXPECTED_OPERATOR_IMAGE}]. The smoke test has FAILED!"
fi

if ! ${CLIENT_EXE} wait deployment -l app.kubernetes.io/name=kiali-operator --for=condition=Available -n ${OPERATOR_NAMESPACE} --timeout=5m; then
  ${CLIENT_EXE} describe deployments -n ${OPERATOR_NAMESPACE} || true
  abort_now "The operator deployment failed to become available. The smoke test has FAILED!"
fi
if ! ${CLIENT_EXE} wait pods -l app.kubernetes.io/name=kiali-operator --for=condition=Ready -n ${OPERATOR_NAMESPACE} --timeout=5m; then
  ${CLIENT_EXE} describe deployments -n ${OPERATOR_NAMESPACE} || true
  ${CLIENT_EXE} describe pods -n ${OPERATOR_NAMESPACE} || true
  ${CLIENT_EXE} logs -l app.kubernetes.io/name=kiali-operator -n ${OPERATOR_NAMESPACE} || true
  abort_now "The operator pod failed to start. The smoke test has FAILED!"
fi

if ! ${HELM_EXE} uninstall --namespace ${OPERATOR_NAMESPACE} kiali-operator; then
  abort_now "The Operator Helm Chart was unable to perform an uninstall successfully. The smoke test has FAILED!"
fi

# SMOKE TESTING THE SERVER

infomsg "Smoke testing server version [${SERVER_VERSION}]"

if ! ${HELM_EXE} install --create-namespace --namespace ${SERVER_NAMESPACE} kiali-server docs/kiali-server-${SERVER_VERSION}.tgz; then
  abort_now "The Server Helm Chart did not install successfully. The smoke test has FAILED!"
fi

ACTUAL_SERVER_IMAGE="$(${CLIENT_EXE} get deployments -n ${SERVER_NAMESPACE} -l app.kubernetes.io/name=kiali -o 'jsonpath={.items..spec.containers[0].image}{"\n"}')"
EXPECTED_SERVER_IMAGE="quay.io/kiali/kiali:v${SERVER_VERSION}"
if [ "${ACTUAL_SERVER_IMAGE}" != "${EXPECTED_SERVER_IMAGE}" ]; then
  abort_now "The actual server image [${ACTUAL_SERVER_IMAGE}] is not the expected image [${EXPECTED_SERVER_IMAGE}]. The smoke test has FAILED!"
fi

if ! ${CLIENT_EXE} wait deployment -l app.kubernetes.io/name=kiali --for=condition=Available -n ${SERVER_NAMESPACE} --timeout=5m; then
  ${CLIENT_EXE} describe deployments -n ${SERVER_NAMESPACE} || true
  abort_now "The server deployment failed to become available. The smoke test has FAILED!"
fi
if ! ${CLIENT_EXE} wait pods -l app.kubernetes.io/name=kiali --for=condition=Ready -n ${SERVER_NAMESPACE} --timeout=5m; then
  ${CLIENT_EXE} describe deployments -n ${SERVER_NAMESPACE} || true
  ${CLIENT_EXE} describe pods -n ${SERVER_NAMESPACE} || true
  ${CLIENT_EXE} logs -l app.kubernetes.io/name=kiali -n ${SERVER_NAMESPACE} || true
  abort_now "The server pod failed to start. The smoke test has FAILED!"
fi

if ! ${HELM_EXE} uninstall --namespace ${SERVER_NAMESPACE} kiali-server; then
  abort_now "The Server Helm Chart was unable to perform an uninstall successfully. The smoke test has FAILED!"
fi

# SMOKE TESTING THAT THE OSSMC IMAGE IS ON QUAY.IO

# Do not check if OSSMC image is on quay. The OSSMC image will not be on quay when this smoke test script is run.
# See https://github.com/kiali/kiali/issues/6865#issuecomment-2096469036

#OSSMC_VERSION="${SERVER_VERSION}"
#EXPECTED_OSSMC_IMAGE="quay.io/kiali/ossmconsole:v${OSSMC_VERSION}"
#infomsg "Checking that the OSSMC image is published on quay.io at: ${EXPECTED_OSSMC_IMAGE}"
#if ! docker pull ${EXPECTED_OSSMC_IMAGE} &>/dev/null ; then
#  abort_now "The OSSMC image is not published on quay.io. This is missing: [${EXPECTED_OSSMC_IMAGE}]. The smoke test has FAILED!"
#fi

# SMOKE TESTING IS COMPLETE

infomsg "========================="
infomsg "The smoke test has PASSED"
infomsg "========================="

restore_env
