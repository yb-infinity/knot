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

# Function to install dependencies
install_dependencies() {
    log_info "Installing dependencies for Knot DNS libraries only..."

    # Add Gemfury repository for XDP packages
    log_info "Adding Gemfury repository..."
    cat > /etc/yum.repos.d/fury.repo << EOF
[fury]
name=Gemfury Repo
baseurl=$FURY_REPO_URL
enabled=1
gpgcheck=0
EOF
    log_success "Gemfury repository added"

    # Update package manager
    log_info "Updating package manager..."
    dnf update -y -q || { log_error "Failed to update packages"; exit 1; }
    dnf makecache -q || log_warning "Cache update completed with warnings"

    # Clean up conflicting packages
    log_info "Removing conflicting kernel packages..."
    dnf remove -y -q 'kernel6.12*' '*bpftool*' 2>/dev/null || true
    dnf clean all
    echo "exclude=kernel6.12* *bpftool-6.12*" >> /etc/dnf/dnf.conf

    # Install basic build tools
    log_info "Installing basic build tools..."
    dnf install -y -q \
      git rpm-build rpmdevtools make gcc autoconf automake libtool \
      pkgconfig m4 tar gzip || { log_error "Failed to install basic tools"; exit 1; }

    # Install CORE dependencies (required for libraries)
    log_info "Installing core library dependencies..."
    dnf install -y -q \
      userspace-rcu-devel \
      gnutls-devel \
      lmdb-devel || { log_error "Failed to install core dependencies"; exit 1; }

    # Install XDP dependencies (required for libknot XDP support)
    log_info "Installing XDP dependencies from Fury repository..."
    dnf install -y -q --allowerasing \
      elfutils-libelf elfutils-libelf-devel \
      kernel-libbpf kernel-libbpf-devel \
      libxdp libxdp-devel \
      xdp-tools || { log_error "CRITICAL: XDP dependencies installation failed"; exit 1; }

    # Verify critical XDP packages
    rpm -q kernel-libbpf-devel libxdp-devel || {
        log_error "CRITICAL: XDP development packages not installed"; exit 1;
    }

    log_success "All required dependencies installed"

    # Note: The following dependencies are NOT needed for libraries-only build:
    # - libedit-devel (used only in utilities like kdig, khost)
    # - libcap-ng-devel (used only in daemon and utilities)
    # - libidn2-devel (used only in utilities for internationalized domains)
    # - libmnl-devel (used only in kxdpgun utility)
    # - libnghttp2-devel (used only in utilities for DoH support)
    # - systemd-devel (explicitly disabled with --disable-systemd)
    # - protobuf-c-devel (used only for dnstap, disabled with --disable-dnstap)
    # - fstrm-devel (used only for dnstap, disabled with --disable-dnstap)
}

# Function to setup RPM build environment
setup_rpm_environment() {
    log_info "Setting up RPM build environment..."

    # Setup RPM build environment
    rpmdev-setuptree

    log_success "RPM build environment set up"
}

timestamp_to_tag() {
    local timestamp="$1"
    local hex=$(printf "%x" "$timestamp")
    echo "dmz${hex}"
}

# Function to show dependency status
show_dependency_status() {
    log_info "=== Dependency Status Check ==="

    log_info "Core library dependencies:"
    rpm -q userspace-rcu-devel gnutls-devel lmdb-devel 2>/dev/null || log_warning "Some core dependencies missing"

    log_info "XDP dependencies:"
    rpm -q kernel-libbpf-devel libxdp-devel 2>/dev/null || log_warning "XDP dependencies missing"

    log_info "Build tools:"
    rpm -q gcc autoconf automake libtool rpm-build 2>/dev/null || log_warning "Build tools missing"
}

# Function to create source archive
create_source_archive() {
    log_info "Creating source archive..."

    cd "$WORKSPACE_DIR"

    # Configure and create source archive
    log_info "Configuring and creating source archive..."
    autoreconf -if || { log_error "autoreconf failed"; exit 1; }
    chmod +x configure || { log_error "Failed to make configure executable"; exit 1; }
    ./configure \
      --enable-silent-rules \
      --disable-documentation \
      --disable-daemon \
      --disable-utilities \
      --disable-modules \
      --disable-systemd \
      --disable-dnstap \
      --with-module-geoip=no \
      --disable-maxminddb \
      --enable-xdp \
      --enable-shared \
      --enable-static || { log_error "configure failed"; exit 1; }
    make dist || { log_error "make dist failed"; exit 1; }

    # Find the created archive
    ARCHIVE=$(ls -1t knot-*.tar.xz | head -1)
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

    # Setup spec file paths
    SPEC_TEMPLATE="${SPEC_TEMPLATE:-$WORKSPACE_DIR/distro/pkg/rpm/knot-libs.spec}"
    [ -f "$SPEC_TEMPLATE" ] || { log_error "Spec template not found: $SPEC_TEMPLATE"; exit 1; }

    SPEC_BASENAME=$(basename "$SPEC_TEMPLATE")
    SPEC_FILE_PATH="$HOME/rpmbuild/SPECS/$SPEC_BASENAME"
    cp "$SPEC_TEMPLATE" "$SPEC_FILE_PATH" || { log_error "Failed to copy spec file"; exit 1; }

    # Parse version from archive name
    SOURCE_VERSION=$(echo $ARCHIVE | sed 's/knot-\(.*\)\.tar\.xz/\1/')

    # Extract base version (remove everything after '+' and '.dev0' suffix)
    RPM_VERSION="${SOURCE_VERSION%%+*}"        # Remove git suffix if present
    RPM_VERSION="${RPM_VERSION%.dev0}"         # Remove dev0 suffix if present

    # Generate timestamp-based release value
    BUILD_TIMESTAMP="${BUILD_TIMESTAMP:-$(date '+%Y%m%d%H%M%S')}"
    RELEASE_VALUE=$(timestamp_to_tag "$BUILD_TIMESTAMP")

    log_info "Source version: $SOURCE_VERSION"
    log_info "RPM version: $RPM_VERSION"
    log_info "Release: $RELEASE_VALUE"

    # Update spec file with variables
    CURRENT_DATE=$(date '+%a %b %d %Y')

    # Use sed with different delimiters to avoid escaping issues
    sed -i "s|{{ source_version }}|$SOURCE_VERSION|g" "$SPEC_FILE_PATH"
    sed -i "s|{{ rpm_version }}|$RPM_VERSION|g" "$SPEC_FILE_PATH"
    sed -i "s|{{ release }}|$RELEASE_VALUE|g" "$SPEC_FILE_PATH"
    sed -i "s|{{ now }}|$CURRENT_DATE|g" "$SPEC_FILE_PATH"

    log_success "Spec file prepared"
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

# Function to copy built packages and verify
copy_and_verify_packages() {
    log_info "Copying built packages to output directory..."

    # Clean and create output directories
    rm -rf "$OUTPUT_DIR/RPMS" "$OUTPUT_DIR/SRPMS"
    mkdir -p "$OUTPUT_DIR/RPMS" "$OUTPUT_DIR/SRPMS"

    # Copy packages with error checking
    [ -d ~/rpmbuild/RPMS ] && [ "$(ls -A ~/rpmbuild/RPMS 2>/dev/null)" ] || {
        log_error "No RPMS found - build failed"; exit 1;
    }
    [ -d ~/rpmbuild/SRPMS ] && [ "$(ls -A ~/rpmbuild/SRPMS 2>/dev/null)" ] || {
        log_error "No SRPMS found - build failed"; exit 1;
    }

    cp -r ~/rpmbuild/RPMS/* "$OUTPUT_DIR/RPMS/"
    cp ~/rpmbuild/SRPMS/* "$OUTPUT_DIR/SRPMS/"

    log_success "Packages copied successfully"

    # Show package verification
    log_info "=== Built packages ==="
    find "$OUTPUT_DIR" -name "*.rpm" -type f -exec basename {} \; | sort
}

# Function to show final results
show_results() {
    log_success "=== Build completed successfully! ==="
    log_info "Output directory: $OUTPUT_DIR"

    log_info "=== Library packages built ==="
    find "$OUTPUT_DIR" -name "lib*.rpm" -type f -exec basename {} \; | head -10
}

# Main execution
main() {
    cd "$WORKSPACE_DIR"

    # Install dependencies
    install_dependencies
    show_dependency_status

    # Build workflow
    setup_rpm_environment
    create_source_archive
    prepare_spec_file

    build_rpm_packages
    copy_and_verify_packages
    show_results

    log_success "Knot DNS Amazon Linux 2023 RPM build completed!"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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
            echo "  --output-dir DIR  Set output directory (default: \$WORKSPACE/rpmbuild-output)"
            echo "  --workspace DIR   Set workspace directory (default: current directory)"
            echo "  --help            Show this help message"
            echo ""
            echo "Environment variables:"
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
