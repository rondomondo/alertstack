#!/usr/bin/env bash

# cd to the directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

PYVER=3.10
SUDO="sudo -s"
PIP=pip3
PYTHON=python3
VENV_DIR=".venv"

GT='✅'
RX='⛔'



# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

function logfg() {
    local l=$1
    printf "${GREEN}${l}${NC}"
}

function logfy() {
    local l=$1
    printf "${YELLOW}${l}${NC}"
}


function logf() {
    local l=$1
    printf "${l}"
}

function create_dirs() {
    local dirs=("$@")
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            echo "Directory $dir does not exist. Creating it now..."
            mkdir -p "$dir"
            if [ $? -eq 0 ]; then
                echo "Successfully created $dir"
            else
                echo "Failed to create $dir"
            fi
        else
            echo "Directory $dir already exists"
        fi
    done
}

function check_python_version() {
    VENV_NAME="python${PYVER}-venv"
    if [ -d "$VENV_NAME" ]; then
        source "$VENV_NAME/bin/activate"
        PYTHON_VERSION=$(python -c "import sys; print(sys.version_info[0])")
        deactivate

        if (( PYTHON_VERSION >= 3 )); then
            echo "Virtual environment '$VENV_NAME' is active and uses Python version $PYTHON_VERSION. Minimum version of 3.8 is expected."
        else
            echo "Virtual environment '$VENV_NAME' uses Python version $PYTHON_VERSION, which is below the minimum required version of 3.8."
        fi
    else
        echo "Virtual environment '$VENV_NAME' does not exist."
    fi
}

function create_venv() {
    logf "\n# Do we have virtualenv support in (${VENV_DIR})"
    if [ ! -d "${VENV_DIR}" ]; then
        logf " - NO ${RX}\n"
        logf "\n# Creating a python virtual env in ${VENV_DIR} \n\n"
        ${PYTHON} -m venv "${VENV_DIR}"
        logf "\n# Created a python virtual env in ${VENV_DIR}"
        logf "  - CREATED ${GT}\n"
    else
        logf "  - YES ${GT}\n"
    fi
}

function check_venv_is_activated() {
    logf "\n# Is the virtual env in (${VENV_DIR}) activated?"
    if [ -z "${VIRTUAL_ENV}" ]; then
        logf " - NO ${RX}\n"
        logfy "# Activate virtual env (in ${VENV_DIR}) with the command:\n\n"
        logfg "source ${VENV_DIR}/bin/activate\n\n"
        logfy "# Then re-run make\n\n"
        exit 1
    else
        logf "    - ACTIVE ${GT}\n"
    fi

    return 0
}

logf "\n#  === Checking for any necessary dependencies ===\n"

create_venv
check_venv_is_activated

exit
