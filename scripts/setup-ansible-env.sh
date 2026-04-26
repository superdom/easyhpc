#!/bin/bash
set -euo pipefail

# EasyHPC Ansible Environment Setup Script
# Supports: RHEL 9, Ubuntu 22.04/24.04

# Determine current directory and root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENV_DIR="${PROJECT_ROOT}/venv"
DEFAULT_ANSIBLE_VERSION="2.20.0"
# Preferred Python interpreter (will be updated after dependency install)
PYTHON_BIN="python3"
# Path to Ansible collections requirements file
COLLECTIONS_REQUIREMENTS_FILE="${PROJECT_ROOT}/collections/requirements.yml"
# ANSIBLE_VERSION now refers to ansible-core version (ansible meta package uses different numbering)
ANSIBLE_VERSION="${ANSIBLE_VERSION:-$DEFAULT_ANSIBLE_VERSION}"

# Minimum requirements
MIN_ANSIBLE_VERSION="2.20"
MIN_PYTHON_VERSION="3.12"
REQUIRED_PYTHON_VERSION="$MIN_PYTHON_VERSION"

# Supported OS versions
SUPPORTED_OS=("rhel:9" "rocky:9" "ubuntu:22.04" "ubuntu:24.04")

version_ge() {
    # Compare two dotted versions (major.minor) and return true if $1 >= $2
    local a_major a_minor b_major b_minor
    a_major=$(echo "$1" | cut -d. -f1)
    a_minor=$(echo "$1" | cut -d. -f2)
    b_major=$(echo "$2" | cut -d. -f1)
    b_minor=$(echo "$2" | cut -d. -f2)

    if [ "$a_major" -gt "$b_major" ]; then
        return 0
    elif [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -ge "$b_minor" ]; then
        return 0
    else
        return 1
    fi
}

determine_required_python_version() {
    # Force Python 3.12+ for all supported platforms
    REQUIRED_PYTHON_VERSION="3.12"
}

# Exit if run as root
if [ $(id -u) -eq 0 ]; then
    echo "ERROR: Please run as a regular user, not as root" >&2
    exit 1
fi

# Load OS information
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION_ID="$VERSION_ID"
elif [ -f /etc/redhat-release ]; then
    OS_ID="rhel"
    OS_VERSION_ID=$(cat /etc/redhat-release | sed -E 's/.*release ([0-9]+).*/\1/')
else
    echo "ERROR: Cannot detect operating system" >&2
    exit 1
fi
OS_VERSION_MAJOR=$(echo "$OS_VERSION_ID" | cut -d. -f1)

# Disable interactive prompts from Apt
export DEBIAN_FRONTEND=noninteractive

# Check Python version
check_python_version() {
    local python_cmd="$1"
    local required_version="$2"

    if ! command -v "$python_cmd" &> /dev/null; then
        echo "ERROR: ${python_cmd} not found. Please install Python ${required_version} or higher." >&2
        exit 1
    fi

    PYTHON_VERSION=$("$python_cmd" --version 2>&1 | awk '{print $2}')
    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

    REQUIRED_MAJOR=$(echo "$required_version" | cut -d. -f1)
    REQUIRED_MINOR=$(echo "$required_version" | cut -d. -f2)

    if [ "$PYTHON_MAJOR" -lt "$REQUIRED_MAJOR" ] || ([ "$PYTHON_MAJOR" -eq "$REQUIRED_MAJOR" ] && [ "$PYTHON_MINOR" -lt "$REQUIRED_MINOR" ]); then
        echo "ERROR: Python $PYTHON_VERSION is below minimum requirement (${required_version}+)" >&2
        exit 1
    fi

    echo "Python version: $PYTHON_VERSION (meets requirement ${required_version}+)"
}

select_python_interpreter() {
    local preferred="python${REQUIRED_PYTHON_VERSION}"

    if command -v "$preferred" >/dev/null 2>&1; then
        PYTHON_BIN="$preferred"
    elif command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
    else
        echo "ERROR: No suitable Python interpreter found." >&2
        exit 1
    fi
}

bootstrap_python_tools() {
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        echo "ERROR: Python interpreter not found: $PYTHON_BIN" >&2
        exit 1
    fi

    echo "Preparing venv tooling for $PYTHON_BIN..."
    if ! "$PYTHON_BIN" -c "import venv" >/dev/null 2>&1; then
        echo "WARNING: venv module not available for ${PYTHON_BIN}. Will try virtualenv if present." >&2
    fi
}

# Check Ansible version requirement
check_ansible_version() {
    local ansible_ver="$1"

    if [ "$ansible_ver" == "latest" ]; then
        return 0
    fi

    local major=$(echo "$ansible_ver" | cut -d. -f1)
    local minor=$(echo "$ansible_ver" | cut -d. -f2)

    if [ "$major" -lt 2 ] || ([ "$major" -eq 2 ] && [ "$minor" -lt 14 ]); then
        echo "ERROR: Ansible version $ansible_ver is below minimum requirement (${MIN_ANSIBLE_VERSION}+)" >&2
        exit 1
    fi
}

install_python_for_ubuntu() {
    local need_install=false
    local need_venv=false

    if ! command -v python3.12 >/dev/null 2>&1; then
        need_install=true
        need_venv=true
    elif ! python3.12 -c "import venv" >/dev/null 2>&1; then
        need_venv=true
    fi

    if [ "$need_install" == "false" ] && [ "$need_venv" == "false" ]; then
        return 0
    fi

    echo "Installing Python ${REQUIRED_PYTHON_VERSION} for Ubuntu ${OS_VERSION_ID}..."
    if [ "$OS_VERSION_ID" == "22.04" ]; then
        sudo apt-get -yq install software-properties-common
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        sudo apt-get -q update
    else
        sudo apt-get -q update
    fi

    sudo apt-get -yq install python3.12 python3.12-venv
}

install_python_for_rhel() {
    if command -v python3.12 >/dev/null 2>&1; then
        return 0
    fi

    echo "Installing Python ${REQUIRED_PYTHON_VERSION} for ${OS_ID} ${OS_VERSION_ID}..."

    sudo "$PKG_MGR" -y -q install python3.12 python3.12-pip python3.12-setuptools || true

    if ! command -v python3.12 >/dev/null 2>&1; then
        echo "ERROR: Failed to install Python 3.12. Please ensure appropriate repositories are enabled (e.g., CRB/AppStream/EPEL)." >&2
        exit 1
    fi
}

# Check OS support
check_os_support() {
    local version_for_check="$OS_VERSION_ID"

    case "$OS_ID" in
        rhel|centos|rocky|almalinux)
            version_for_check="$OS_VERSION_MAJOR"
            ;;
    esac

    local os_key="${OS_ID}:${version_for_check}"
    local supported=false

    for supported_os in "${SUPPORTED_OS[@]}"; do
        if [ "$os_key" == "$supported_os" ]; then
            supported=true
            break
        fi
    done

    if [ "$supported" == "false" ]; then
        echo "WARNING: OS ${OS_ID} ${OS_VERSION_ID} is not officially supported" >&2
        echo "Supported OS: ${SUPPORTED_OS[*]}" >&2
        echo "Continuing anyway..." >&2
    fi
}

# Install software dependencies
install_dependencies() {
    echo "Installing required dependencies..."

    case "$OS_ID" in
        rhel|centos|rocky|almalinux)
            # Determine package manager (RHEL 8/9 use dnf, older use yum)
            if command -v dnf &> /dev/null; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi

            # Enable EPEL (required for sshpass package)
            if [ "$OS_VERSION_MAJOR" == "8" ] || [ "$OS_VERSION_MAJOR" == "9" ]; then
                EPEL_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION_MAJOR}.noarch.rpm"
                sudo "$PKG_MGR" -y -q install "${EPEL_URL}" >/dev/null 2>&1 || true
            fi

            # Install dependencies for RHEL 9
            DEPENDENCIES=(git python3-libselinux sshpass wget)
            sudo "$PKG_MGR" -y -q install "${DEPENDENCIES[@]}"
            install_python_for_rhel
            ;;
        ubuntu|debian)
            # Install dependencies for Ubuntu 22.04/24.04
            DEPENDENCIES=(git virtualenv python3-virtualenv sshpass wget)
            sudo apt-get -q update
            sudo apt-get -yq install "${DEPENDENCIES[@]}"
            install_python_for_ubuntu
            ;;
        *)
            echo "ERROR: Unsupported operating system: $OS_ID" >&2
            exit 1
            ;;
    esac

    echo "Dependencies installed"
}

# Create virtual environment and install python dependencies
create_venv_and_install() {
    echo "Creating virtual environment..."

    if ! command -v "$PYTHON_BIN" &> /dev/null; then
        echo "ERROR: Python interpreter not found: $PYTHON_BIN" >&2
        exit 1
    fi

    # Remove existing venv if it exists
    if [ -d "$VENV_DIR" ]; then
        echo "Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    fi

    # Create virtual environment
    mkdir -p "$(dirname "$VENV_DIR")"
    if "$PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1; then
        :
    else
        echo "WARNING: Failed to create venv with $PYTHON_BIN -m venv. Trying virtualenv..." >&2
        if command -v virtualenv >/dev/null 2>&1; then
            virtualenv -q --python="$(command -v "$PYTHON_BIN")" "${VENV_DIR}"
        else
            echo "ERROR: Failed to create virtual environment. Install python${REQUIRED_PYTHON_VERSION}-venv or virtualenv." >&2
            exit 1
        fi
    fi

    # Activate virtual environment
    . "${VENV_DIR}/bin/activate"

    # Ensure pip is available inside the virtual environment
    python -m ensurepip --upgrade >/dev/null 2>&1 || true
    if ! python -m pip --version >/dev/null 2>&1; then
        echo "ERROR: pip is not available in the virtual environment." >&2
        exit 1
    fi

    # Upgrade pip
    echo "Upgrading pip..."
    python -m pip install -q --upgrade pip setuptools wheel

    # Check for existing Ansible (core) installation
    if python -m pip show ansible-core >/dev/null 2>&1; then
        current_version=$(python -m pip show ansible-core | grep Version | awk '{print $2}')
        echo "Current Ansible (core) version: ${current_version}"

        if [ "$ANSIBLE_VERSION" != "latest" ]; then
            # Simple version comparison
            current_major=$(echo "$current_version" | cut -d. -f1)
            current_minor=$(echo "$current_version" | cut -d. -f2)
            target_major=$(echo "$ANSIBLE_VERSION" | cut -d. -f1)
            target_minor=$(echo "$ANSIBLE_VERSION" | cut -d. -f2)

            if [ "$current_major" -lt "$target_major" ] || \
               ([ "$current_major" -eq "$target_major" ] && [ "$current_minor" -lt "$target_minor" ]); then
                echo "Ansible will be upgraded from ${current_version} to ${ANSIBLE_VERSION}"
            elif [ "$current_version" == "$ANSIBLE_VERSION" ]; then
                echo "Ansible ${current_version} is already installed."
                return 0
            fi
        fi
    fi

    # Install Ansible (core)
    echo "Installing Ansible (core) ${ANSIBLE_VERSION}..."
    if [ "$ANSIBLE_VERSION" == "latest" ]; then
        python -m pip install -q --upgrade ansible ansible-core
    else
        python -m pip install -q --upgrade "ansible-core==${ANSIBLE_VERSION}"
    fi

    # Verify installation
    if ! command -v ansible &> /dev/null; then
        echo "ERROR: Failed to install Ansible" >&2
        exit 1
    fi

    ANSIBLE_INSTALLED_VER=$(ansible --version | head -n1 | awk '{print $2}')
    echo "Ansible (core) ${ANSIBLE_INSTALLED_VER} installed successfully"

    # Install Ansible collections
    echo "Installing Ansible collections..."
    if [ ! -f "$COLLECTIONS_REQUIREMENTS_FILE" ]; then
        echo "ERROR: Collections requirements file not found: $COLLECTIONS_REQUIREMENTS_FILE" >&2
        exit 1
    fi
    ansible-galaxy collection install -r "$COLLECTIONS_REQUIREMENTS_FILE" --force >/dev/null
    echo "Ansible collections installed (from $COLLECTIONS_REQUIREMENTS_FILE)"
}

# Add virtual environment to .bashrc
add_to_bashrc() {
    local bashrc_file="$HOME/.bashrc"
    local activation_line="source ${VENV_DIR}/bin/activate"

    echo "Configuring .bashrc for automatic activation..."

    # Check if .bashrc exists, create if not
    if [ ! -f "$bashrc_file" ]; then
        touch "$bashrc_file"
        chmod 644 "$bashrc_file"
    fi

    # Check if already added
    if grep -q "source.*${VENV_DIR}/bin/activate" "$bashrc_file" 2>/dev/null; then
        echo "Virtual environment is already configured in $bashrc_file"
        return 0
    fi

    # Append to .bashrc (preserving existing content)
    # Add a newline if file doesn't end with one
    if [ -s "$bashrc_file" ] && [ "$(tail -c 1 "$bashrc_file")" != "" ]; then
        echo "" >> "$bashrc_file"
    fi
    echo "# Ansible virtual environment (added by setup-ansible-env.sh)" >> "$bashrc_file"
    echo "$activation_line" >> "$bashrc_file"

    # Verify it was added
    if grep -q "source.*${VENV_DIR}/bin/activate" "$bashrc_file" 2>/dev/null; then
        echo "Virtual environment has been added to $bashrc_file"
        echo "It will be automatically activated in new shell sessions"
    else
        echo "ERROR: Failed to add configuration to $bashrc_file" >&2
        return 1
    fi
}

# Main function
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                ANSIBLE_VERSION="$2"
                shift 2
                ;;
            -f|--force)
                if [ -d "$VENV_DIR" ]; then
                    rm -rf "$VENV_DIR"
                fi
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    echo "=========================================="
    echo "Ansible Environment Setup"
    echo "=========================================="
    echo "OS: ${OS_ID} ${OS_VERSION_ID}"
    echo "Ansible (core) version: $ANSIBLE_VERSION"
    echo "Required Python version: ${MIN_PYTHON_VERSION}+"
    echo "Virtual environment: $VENV_DIR"
    echo "=========================================="
    echo ""

    # Check OS support
    check_os_support
    echo ""

    # Check requirements
    check_ansible_version "$ANSIBLE_VERSION"
    determine_required_python_version
    echo "Required Python version for Ansible (core) ${ANSIBLE_VERSION}: ${REQUIRED_PYTHON_VERSION}+"
    echo ""

    # Install dependencies
    install_dependencies
    echo ""

    # Select and validate Python interpreter
    select_python_interpreter
    check_python_version "$PYTHON_BIN" "$REQUIRED_PYTHON_VERSION"
    echo ""

    # Prepare venv tooling for the selected interpreter
    bootstrap_python_tools
    echo ""

    # Create virtual environment and install Ansible
    create_venv_and_install
    echo ""

    # Add to .bashrc
    add_to_bashrc
    echo ""

    echo "=========================================="
    echo "Setup completed!"
    echo "=========================================="
    echo "Virtual environment: $VENV_DIR"
    echo ""
    echo "To activate in current shell session, run:"
    echo "  source $VENV_DIR/bin/activate"
    echo ""
    echo "Or from the project root:"
    echo "  source venv/bin/activate"
    echo ""
    echo "The virtual environment will be automatically activated"
    echo "in new shell sessions (due to the .bashrc entry)."
    echo "If you need this script to activate the environment immediately,"
    echo "run it via 'source scripts/setup-ansible-env.sh'."
    echo ""
}

main "$@"
