%global _hardened_build 1
%global debug_package %{nil}
%global _enable_debug_packages 0
%{!?_pkgdocdir: %global _pkgdocdir %{_docdir}/%{name}}

Summary: Knot DNS shared libraries
Name: libknot
Version: {{ rpm_version }}
Release: {{ release }}%{?dist}
License: GPL-3.0-or-later
URL: https://www.knot-dns.cz
Source0: knot-{{ source_version }}.tar.xz

BuildRequires: autoconf
BuildRequires: automake
BuildRequires: libtool
BuildRequires: make
BuildRequires: gcc
BuildRequires: pkgconfig(liburcu)
BuildRequires: pkgconfig(gnutls)
BuildRequires: pkgconfig(libbpf)
BuildRequires: pkgconfig(libxdp)
BuildRequires: pkgconfig(lmdb)

%description
libknot provides the high-performance core shared library used by Knot DNS.

%package -n libdnssec
Summary: DNSSEC shared library from Knot DNS
Requires: libknot%{?_isa} = %{version}-%{release}

%description -n libdnssec
libdnssec provides DNSSEC signing and validation primitives used by Knot DNS.

%package -n libzscanner
Summary: Zone file parser shared library from Knot DNS
Requires: libknot%{?_isa} = %{version}-%{release}

%description -n libzscanner
libzscanner provides high-performance zone file parsing for Knot DNS.

%package -n libknot-devel
Summary: Development files for libknot
Requires: libknot%{?_isa} = %{version}-%{release}

%description -n libknot-devel
Header files and metadata required to develop against libknot.

%package -n libdnssec-devel
Summary: Development files for libdnssec
Requires: libdnssec%{?_isa} = %{version}-%{release}

%description -n libdnssec-devel
Header files and metadata required to develop against libdnssec.

%package -n libzscanner-devel
Summary: Development files for libzscanner
Requires: libzscanner%{?_isa} = %{version}-%{release}

%description -n libzscanner-devel
Header files and metadata required to develop against libzscanner.

%prep
%autosetup -n knot-{{ source_version }}

%build
CFLAGS="%{optflags} -DNDEBUG -Wno-unused"
%configure \
  --sysconfdir=%{_sysconfdir} \
  --localstatedir=%{_localstatedir} \
  --disable-daemon \
  --disable-modules \
  --disable-utilities \
  --disable-documentation \
  --enable-systemd=no \
  --enable-dbus=no \
  --enable-dnstap=no \
  --with-module-dnstap=no \
  --with-module-geoip=no \
  --enable-maxminddb=no \
  --enable-xdp=yes \
  --disable-static \
  --enable-shared
%make_build

%install
%make_install

# remove everything except shared libraries and development files
rm -rf %{buildroot}%{_bindir}
rm -rf %{buildroot}%{_sbindir}
rm -rf %{buildroot}%{_libexecdir}
rm -rf %{buildroot}%{_sysconfdir}
rm -rf %{buildroot}%{_sharedstatedir}
rm -rf %{buildroot}%{_localstatedir}
rm -rf %{buildroot}%{_datadir}
rm -rf %{buildroot}%{_mandir}
rm -rf %{buildroot}%{_libdir}/knot
find %{buildroot}%{_libdir} -maxdepth 1 -name "lib*.la" -delete
find %{buildroot} -type f -name "*.la" -delete

# install documentation and licenses for each package
install -d %{buildroot}%{_pkgdocdir}
install -pm 0644 NEWS README.md %{buildroot}%{_pkgdocdir}

install -d %{buildroot}%{_licensedir}/libknot
install -pm 0644 COPYING %{buildroot}%{_licensedir}/libknot/COPYING

install -d %{buildroot}%{_licensedir}/libdnssec
install -pm 0644 COPYING %{buildroot}%{_licensedir}/libdnssec/COPYING

install -d %{buildroot}%{_licensedir}/libzscanner
install -pm 0644 COPYING %{buildroot}%{_licensedir}/libzscanner/COPYING

%files
%license %{_licensedir}/libknot/COPYING
%doc %{_pkgdocdir}/NEWS
%doc %{_pkgdocdir}/README.md
%{_libdir}/libknot.so.*

%files -n libdnssec
%license %{_licensedir}/libdnssec/COPYING
%{_libdir}/libdnssec.so.*

%files -n libzscanner
%license %{_licensedir}/libzscanner/COPYING
%{_libdir}/libzscanner.so.*

%files -n libknot-devel
%{_includedir}/knot
%{_includedir}/libknot
%{_libdir}/libknot.so
%{_libdir}/pkgconfig/libknot.pc

%files -n libdnssec-devel
%{_includedir}/libdnssec
%{_libdir}/libdnssec.so
%{_libdir}/pkgconfig/libdnssec.pc

%files -n libzscanner-devel
%{_includedir}/libzscanner
%{_libdir}/libzscanner.so
%{_libdir}/pkgconfig/libzscanner.pc

%changelog
* {{ now }} Knot DNS <knot-dns@labs.nic.cz> - {{ rpm_version }}-{{ release }}
- libraries only build for Amazon Linux 2023
