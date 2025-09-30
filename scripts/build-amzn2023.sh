#!/bin/bash
set -e

# Knot DNS Amazon Linux 2023 RPM Build Script
# This script can be used both in GitHub Actions and for local builds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running in container
IN_CONTAINER=${IN_CONTAINER:-false}
if [ -f /.dockerenv ]; then
    IN_CONTAINER=true
fi

# Configuration
WORKSPACE_DIR=${WORKSPACE_DIR:-$(pwd)}
FURY_REPO_URL=${FURY_REPO_URL:-"https://yum.fury.io/drakemazzy/"}
OUTPUT_DIR=${OUTPUT_DIR:-"$WORKSPACE_DIR/rpmbuild-output"}
SPEC_TEMPLATE=${SPEC_TEMPLATE:-}
SPEC_BASENAME=""
SPEC_FILE_PATH=""

log_info "Starting Knot DNS Amazon Linux 2023 RPM build"
log_info "Workspace: $WORKSPACE_DIR"
log_info "Output directory: $OUTPUT_DIR"
log_info "In container: $IN_CONTAINER"

# Function to install dependencies
install_dependencies() {
    log_info "Installing Knot DNS dependencies..."

    # Add Gemfury repository
    log_info "Adding Gemfury repository..."
    cat > /etc/yum.repos.d/fury.repo << EOF
[fury]
name=Gemfury Repo
baseurl=$FURY_REPO_URL
enabled=1
gpgcheck=0
EOF
    log_success "Gemfury repository added successfully"

    # Update package manager
    log_info "Updating package manager..."
    dnf update -y -q || { log_error "Failed to update packages"; exit 1; }

    # Update repository cache
    log_info "Updating repository cache..."
    dnf makecache -q || log_warning "Cache update completed with warnings"

    # Remove conflicting kernel headers and ensure kernel 6.1 is used
    log_info "Removing ALL conflicting kernel packages..."
    dnf remove -y -q 'kernel6.12*' || log_info "No kernel 6.12 packages to remove"
    dnf remove -y -q '*bpftool*' || log_info "No bpftool packages to remove"

    # Clean up any remaining conflicts
    log_info "Cleaning package cache..."
    dnf clean all

    # Install specific kernel 6.1 headers to avoid conflicts
    log_info "Installing kernel 6.1 headers..."
    dnf install -y -q kernel-headers kernel-devel || log_warning "Kernel 6.1 headers installation attempted"

    # Ensure we don't accidentally install wrong kernel tools
    log_info "Preventing installation of wrong kernel version tools..."
    echo "exclude=kernel6.12* *bpftool-6.12*" >> /etc/dnf/dnf.conf

    # Install basic build tools first
    log_info "Installing basic build tools..."
    dnf install -y -q \
      git \
      rpm-build \
      rpmdevtools \
      make \
      gcc \
      autoconf \
      automake \
      libtool \
      pkgconfig \
      m4 \
      tar \
      gzip \
      which \
      findutils || { log_error "Failed to install basic tools"; exit 1; }

    # Install Knot DNS specific dependencies
    log_info "Installing Knot DNS dependencies..."
    dnf install -y -q \
      userspace-rcu-devel \
      gnutls-devel \
      libedit-devel \
      lmdb-devel || { log_error "Failed to install core dependencies"; exit 1; }

    # Install optional dependencies (don't fail if some are missing)
    log_info "Installing optional dependencies..."
    dnf install -y -q \
      libcap-ng-devel \
      libidn2-devel \
      libmnl-devel \
      libnghttp2-devel \
      systemd-devel || log_warning "Some optional dependencies may not be available"

    # Install additional optional dependencies (minimal set for libraries only)
    log_info "Installing minimal optional dependencies for libraries only..."
    dnf install -y -q \
      protobuf-c-devel \
      fstrm-devel || log_warning "Some optional dependencies may not be available"

    # Verify Fury repository is available for XDP packages
    log_info "Verifying Fury repository for XDP packages..."
    dnf repolist | grep fury || { log_error "Fury repository not available"; exit 1; }

    # Install XDP dependencies from Fury repository (REQUIRED)
    log_info "Installing XDP dependencies from Fury repository..."

    log_info "Installing elfutils-libelf and libbpf runtime..."
    dnf install -y -q --allowerasing elfutils-libelf libbpf || { log_error "CRITICAL: runtime libraries installation failed"; exit 1; }

    log_info "Installing libbpf and libxdp runtime libraries..."
    dnf install -y -q --allowerasing kernel-libbpf libxdp || { log_error "CRITICAL: XDP runtime libraries installation failed"; exit 1; }

    log_info "Installing elfutils-libelf-devel from Fury..."
    dnf install -y -q --allowerasing elfutils-libelf-devel || { log_error "CRITICAL: elfutils-libelf-devel installation failed"; exit 1; }

    log_info "Installing kernel-libbpf-devel from Fury..."
    dnf install -y -q --allowerasing kernel-libbpf-devel || { log_error "CRITICAL: kernel-libbpf-devel installation failed"; exit 1; }

    log_info "Installing libxdp-devel from Fury..."
    dnf install -y -q --allowerasing libxdp-devel || { log_error "CRITICAL: libxdp-devel installation failed"; exit 1; }

    log_info "Installing xdp-tools from Fury (avoiding wrong kernel version)..."
    dnf install -y -q --allowerasing --exclude='*6.12*' xdp-tools || { log_error "CRITICAL: xdp-tools installation failed"; exit 1; }

    # Verify critical XDP packages are installed (fail if not)
    log_info "Verifying XDP dependencies installation..."
    if ! rpm -q kernel-libbpf-devel; then
      log_error "CRITICAL ERROR: kernel-libbpf-devel not installed - XDP support required"
      exit 1
    fi
    if ! rpm -q libxdp-devel; then
      log_error "CRITICAL ERROR: libxdp-devel not installed - XDP support required"
      exit 1
    fi
    log_success "XDP dependencies successfully installed from Fury repository"

    log_success "Dependencies installation completed"
}

# Function to setup RPM build environment
setup_rpm_environment() {
    log_info "Setting up RPM build environment..."

    # Setup RPM build environment
    rpmdev-setuptree

    log_success "RPM build environment set up"
}

# Function to show dependency status
show_dependency_status() {
    log_info "=== Dependency Status ==="

    # Check kernel versions and conflicts
    log_info "=== Kernel Headers Status ==="
    rpm -qa | grep -E "kernel.*headers" || log_info "No kernel headers found"
    rpm -qa | grep -E "kernel.*devel" || log_info "No kernel devel packages found"

    # Check available packages for debugging
    log_info "=== Checking available packages ==="
    dnf list available | grep -E "(hiredis|libbpf|libxdp|systemd-devel|python3-sphinx|softhsm)" || log_info "Some packages not found in repositories"

    log_info "=== XDP Dependencies Status ==="
    rpm -qa | grep -E "(libbpf|libxdp|elfutils)" || log_info "XDP dependencies may not be installed"

    log_info "=== Installed development packages ==="
    rpm -qa | grep -E "(devel|pkgconfig)" | sort
}

# Function to create source archive
create_source_archive() {
    log_info "Creating source archive..."

    cd "$WORKSPACE_DIR"

    # XDP configuration (always enabled - required)
    log_info "XDP support is REQUIRED - enabling XDP configuration"
    XDP_CONFIG="--enable-xdp"

    # Configure and create source archive
    log_info "Configuring and creating source archive..."
    autoreconf -if || { log_error "autoreconf failed"; exit 1; }
    chmod +x configure || { log_error "Failed to make configure executable"; exit 1; }
    ./configure \
      --disable-documentation \
      --disable-daemon \
      --disable-utilities \
      --disable-modules \
      --without-module-redis \
      --disable-systemd \
      --disable-dnstap \
      --disable-geoip \
      --disable-maxminddb \
      $XDP_CONFIG \
      --enable-shared \
      --enable-static || { log_error "configure failed"; exit 1; }
    make dist || { log_error "make dist failed"; exit 1; }

    # Find the created archive
    ARCHIVE=$(ls -1 knot-*.tar.xz | head -1)
    if [ -z "$ARCHIVE" ]; then
      log_error "No archive found"
      exit 1
    fi
    log_success "Created archive: $ARCHIVE"

    # Export for later use
    export ARCHIVE
}

# Function to prepare spec file
prepare_spec_file() {
    log_info "Preparing spec file..."

    # Copy source archive to SOURCES
    cp "$ARCHIVE" ~/rpmbuild/SOURCES/ || { log_error "Failed to copy archive"; exit 1; }

    local spec_basename

    if [ -z "$SPEC_TEMPLATE" ]; then
        SPEC_TEMPLATE="$WORKSPACE_DIR/distro/pkg/rpm/knot-libs.spec"
    fi

    if [ ! -f "$SPEC_TEMPLATE" ]; then
        log_error "Spec template not found: $SPEC_TEMPLATE"
        exit 1
    fi

    spec_basename=$(basename "$SPEC_TEMPLATE")
    SPEC_BASENAME="$spec_basename"
    SPEC_FILE_PATH="$HOME/rpmbuild/SPECS/$SPEC_BASENAME"

    # Copy spec template into SPECS directory
    cp "$SPEC_TEMPLATE" "$SPEC_FILE_PATH" || { log_error "Failed to copy spec file"; exit 1; }

    # Get version from archive name
    VERSION=$(echo $ARCHIVE | sed 's/knot-\(.*\)\.tar\.xz/\1/')
    log_info "Detected version: $VERSION"

    # Update spec file with actual version
    CURRENT_DATE=$(date '+%a %b %d %Y')
    sed -i "s/{{ version }}/$VERSION/g" "$SPEC_FILE_PATH" || { log_error "Failed to update version"; exit 1; }
    sed -i "s/{{ release }}/1/g" "$SPEC_FILE_PATH" || { log_error "Failed to update release"; exit 1; }
    sed -i "s/{{ now }}/$CURRENT_DATE/g" "$SPEC_FILE_PATH" || { log_error "Failed to update date"; exit 1; }

    log_success "Spec file prepared"
}

# Function to show spec file debug info
show_spec_debug() {
    if [ -z "$SPEC_FILE_PATH" ] || [ ! -f "$SPEC_FILE_PATH" ]; then
        log_warning "Spec file not prepared yet; skipping debug output"
        return
    fi

    log_info "=== Modified spec file configure section ==="
    grep -A 15 -B 5 '%configure' "$SPEC_FILE_PATH" || log_info "No configure section found"

    log_info "=== Spec file build section ==="
    grep -A 10 -B 2 '^%build' "$SPEC_FILE_PATH" || log_info "No build section found"

    log_info "=== Checking for macro issues in commented lines ==="
    grep '^# .*%{' "$SPEC_FILE_PATH" | head -10 || log_info "No commented macros found"
}

# Function to build RPM packages
build_rpm_packages() {
    log_info "Building Knot DNS RPM packages (3 separate library packages with XDP support)..."

    # Build RPM packages
    if [ -z "$SPEC_BASENAME" ]; then
        log_error "Spec file name not set"
        exit 1
    fi

    cd ~/rpmbuild/SPECS
    rpmbuild -ba "$SPEC_BASENAME" || { log_error "RPM build failed"; exit 1; }

    log_success "RPM packages built successfully"
}

# Function to copy built packages
copy_packages() {
    log_info "Copying built packages to output directory..."

    # Ensure fresh output directories
    rm -rf "$OUTPUT_DIR/RPMS" "$OUTPUT_DIR/SRPMS"
    mkdir -p "$OUTPUT_DIR/RPMS"
    mkdir -p "$OUTPUT_DIR/SRPMS"

    # Check and copy RPMS
    if [ -d ~/rpmbuild/RPMS ] && [ "$(ls -A ~/rpmbuild/RPMS 2>/dev/null)" ]; then
      cp -r ~/rpmbuild/RPMS/* "$OUTPUT_DIR/RPMS/"
      log_success "RPMS copied successfully"

      # List built packages for verification
      log_info "=== Built RPM packages ==="
      find ~/rpmbuild/RPMS -name "*.rpm" -exec basename {} \;
    else
      log_error "No RPMS found - build failed"
      exit 1
    fi

    # Check and copy SRPMS
    if [ -d ~/rpmbuild/SRPMS ] && [ "$(ls -A ~/rpmbuild/SRPMS 2>/dev/null)" ]; then
      cp ~/rpmbuild/SRPMS/* "$OUTPUT_DIR/SRPMS/"
      log_success "SRPMS copied successfully"

      # List source packages
      log_info "=== Built SRPM packages ==="
      find ~/rpmbuild/SRPMS -name "*.rpm" -exec basename {} \;
    else
      log_error "No SRPMS found - build failed"
      exit 1
    fi
}

# Function to verify packages
verify_packages() {
    log_info "=== Package contents verification ==="
    # Show contents of three separate library packages
    for pkg in $(find ~/rpmbuild/RPMS -name "libknot-*.rpm" -o -name "libdnssec-*.rpm" -o -name "libzscanner-*.rpm"); do
      log_info "Contents of $(basename $pkg):"
      rpm -qlp $pkg || true
      echo "---"
    done
}

# Function to show final results
show_results() {
    log_success "=== Build completed successfully! ==="
    log_info "=== All built RPM packages ==="
    find "$OUTPUT_DIR" -name "*.rpm" -type f -exec basename {} \;
    echo ""
    log_info "=== Three separate library packages ==="
    find "$OUTPUT_DIR" -name "libknot-*.rpm" -o -name "libdnssec-*.rpm" -o -name "libzscanner-*.rpm" | head -10

    log_info "Output directory: $OUTPUT_DIR"
}

# Main execution
main() {
    # Change to workspace directory
    cd "$WORKSPACE_DIR"

    # Only install dependencies if in container or requested
    if [ "$IN_CONTAINER" = true ] || [ "$INSTALL_DEPS" = true ]; then
        install_dependencies
        show_dependency_status
    else
        log_info "Skipping dependency installation (not in container and INSTALL_DEPS not set)"
    fi

    setup_rpm_environment
    create_source_archive
    prepare_spec_file

    # Show debug info if requested
    if [ "$SHOW_DEBUG" = true ]; then
        show_spec_debug
    fi

    build_rpm_packages
    copy_packages
    verify_packages
    show_results

    log_success "Knot DNS Amazon Linux 2023 RPM build completed successfully!"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        --show-debug)
            SHOW_DEBUG=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --install-deps    Force installation of dependencies"
            echo "  --show-debug      Show debug information about spec file"
            echo "  --output-dir DIR  Set output directory (default: \$WORKSPACE/rpmbuild-output)"
            echo "  --workspace DIR   Set workspace directory (default: current directory)"
            echo "  --help            Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  IN_CONTAINER      Set to true if running in container (auto-detected)"
            echo "  INSTALL_DEPS      Set to true to force dependency installation"
            echo "  SHOW_DEBUG        Set to true to show debug information"
            echo "  FURY_REPO_URL     Fury repository URL"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main
