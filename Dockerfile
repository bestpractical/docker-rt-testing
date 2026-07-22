FROM debian:trixie-slim

LABEL maintainer="Best Practical Solutions <contact@bestpractical.com>"

ARG CPANFILE=https://raw.githubusercontent.com/bestpractical/rt/6.0-trunk/etc/cpanfile
ARG CPM=https://raw.githubusercontent.com/skaji/cpm/main/cpm
ARG PERL_VERSION=5.34.3
ARG PERL_CONFIGURE="-des"
ARG PERL_PREFIX="/opt/perl-$PERL_VERSION"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    apache2 \
    autoconf \
    build-essential \
    # curl needs CA certificates to verify the authenticity of downloads.
    ca-certificates \
    curl \
    git \
    gnupg \
    graphviz \
    # The Perl getaddrinfo tests rely on /etc/services, provided by netbase.
    netbase \
    w3m \
    # RT core dependencies
    libapache2-mod-fcgid \
    libexpat-dev \
    libgd-dev \
    libmariadb-dev \
    libmariadb-dev-compat \
    libssl-dev \
    libz-dev \
    chromium \
    firefox-esr \
    lsof \
    libaio1t64 \
    alien
# && rm -rf /var/lib/apt/lists/*

# Install PostgreSQL repo for the latest client libraries (libpq)
RUN apt-get install -y postgresql-common
RUN /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Oracle instantclient
#RUN apt-get install -y libaio1 alien
RUN mkdir -p /usr/local/src/oracle-instantclient \
 cd /usr/local/src/oracle-instantclient \
 && curl -sSL --output oracle-instantclient-basic-23.26.2.0.0-2.el8.x86_64.rpm https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient23/x86_64/getPackage/oracle-instantclient-basic-23.26.2.0.0-2.el8.x86_64.rpm \
 && curl -sSL --output oracle-instantclient-devel-23.26.2.0.0-2.el8.x86_64.rpm https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient23/x86_64/getPackage/oracle-instantclient-devel-23.26.2.0.0-2.el8.x86_64.rpm \
 && curl -sSL --output oracle-instantclient-sqlplus-23.26.2.0.0-2.el8.x86_64.rpm https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient23/x86_64/getPackage/oracle-instantclient-sqlplus-23.26.2.0.0-2.el8.x86_64.rpm \
 && alien -i --scripts oracle-instantclient*.rpm \
 && cd /usr/local/src \
 && rm -rf /usr/local/src/oracle-instantclient

ENV ORACLE_HOME=/usr/lib/oracle/23/client64 \
 LD_LIBRARY_PATH=/usr/lib/oracle/23/client64/lib

# Install geckodriver for dashboard email tests
RUN mkdir -p /usr/local/src/geckodriver \
 cd /usr/local/src/geckodriver \
 && curl -sSL https://github.com/mozilla/geckodriver/releases/download/v0.37.1/geckodriver-v0.37.1-linux64.tar.gz | tar xz \
 && cp geckodriver /usr/local/bin \
 && cd /usr/local/src \
 && rm -rf /usr/local/src/geckodriver

# Install Node.js from NodeSource for Playwright
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# Set NODE_PATH to playwright-perl node_modules
ENV NODE_PATH=/opt/playwright-perl/node_modules
ENV PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright

# Install Playwright system dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    # Additional libraries for Playwright browsers
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libatspi2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Install Playwright dependencies from playwright-perl package.json
RUN mkdir -p /opt/playwright-perl \
 && cd /opt/playwright-perl \
 && curl -sSL https://raw.githubusercontent.com/teodesian/playwright-perl/main/package.json -o package.json \
 && npm install \
 && npx playwright install chromium firefox \
 && npx playwright install-deps

RUN cd /usr/local/src \
 && curl --fail --location "https://www.cpan.org/src/5.0/perl-$PERL_VERSION.tar.gz" \
  | tar -xz \
 && cd "perl-$PERL_VERSION" \
 # termios.t tests that tcdrain, tcflow, tcflush, and tcsendbreak all return
 # ENOTTY on a regular file.
 # The underlying ioctls are not implemented on podman 3.0
 # (probably runc/libcontainer) and return ENOSYS instead.
 # This sed simply deletes those tests as a hacky workaround for now,
 # since returning ENOSYS is legitimate.
 && sed -i '/^is(tc/ , /^$/ d' ext/POSIX/t/termios.t \
 && ./Configure -Dprefix="$PERL_PREFIX" $PERL_CONFIGURE \
 # The Net::Ping tests assume they can construct arbitrary packets when $< is 0.
 # This assumption is false when tests are running in a user namespace
 # (e.g., podman) or otherwise without the CAP_NET_RAW capability.
 # See <https://rt.cpan.org/Ticket/Display.html?id=139820>.
 # Run tests as nobody to force $< to be nonzero.
 && chown -R nobody: . \
 # The command: su -s /bin/sh -c "…" nobody
 # is just the sudo-less version of: sudo -u nobody …
 && su -s /bin/sh -c "make test" nobody \
 && make install \
 && cd /opt \
 && ln -s "$PERL_PREFIX" perl \
 && rm -rf "/usr/local/src/perl-$PERL_VERSION"

ENV PATH="/opt/perl/bin:$PATH"

RUN curl --fail --location --compressed -o /opt/perl/bin/cpm "$CPM" \
 && chmod a+rx /opt/perl/bin/cpm

# Install XML::Simple first. Installing in the full bundle of modules below can
# result in test failures, possibly because of which XML parser it ends up using.
RUN cpm install --global --no-prebuilt --no-test --with-all --show-build-log-on-failure XML::Simple

# Install Mail::Sendmail without tests.
# The module has only one test file and it tries to send email to the
# author. Changing the recipient requires changing the test code directly.
# The default address is protected by spamhaus and can fail for home IPs
RUN cpm install --global --no-prebuilt --no-test --with-all --show-build-log-on-failure Mail::Sendmail

# Install Module::Pluggable without tests to avoid some failing tests
# in version 6.2. Hopefully temporary.
RUN cpm install --global --no-prebuilt --no-test --with-all --show-build-log-on-failure Module::Pluggable

# Add optional modules
RUN cpm install --global --no-prebuilt --with-all --show-build-log-on-failure CSS::Inliner
RUN cpm install --global --no-prebuilt --with-all --show-build-log-on-failure WWW::Mechanize::Chrome

# Install Playwright Perl module
RUN cpm install --global --no-prebuilt --with-all --show-build-log-on-failure Playwright

# Install Module::Runtime before the bulk step below. MooX::late 0.100 uses it
# (MooX/late.pm line 12) but does not declare it as a prerequisite.
RUN cpm install --global --no-prebuilt --with-all --show-build-log-on-failure Module::Runtime

RUN cd /tmp \
 && curl --fail --location --compressed -o cpanfile "$CPANFILE" \
 # 1. Find all the features named in RT's cpanfile.
 # 2. Filter out the ones named in the regexp test against $2.
 # 3. Print corresponding `--feature=name` options for cpm.
 # 4. Run cpm with those options, along with a baseline set,
 #    to test and install all dependencies needed to run RT's tests.
 && awk '($1 == "feature" && $2 !~ /(modperl1)/) { print "--feature=" substr($2, 2, length($2) - 2) }' cpanfile \
  | xargs -d\\n --exit --verbose cpm install --global --no-prebuilt --test --with-all --show-build-log-on-failure \
 && rm -rf cpanfile ~/.perl-cpm


CMD cpan -a </dev/null >/dev/null
# CMD cat ~/.cpan/Bundle/Snapshot_*.pm

# Helpful for local docker testing
# CMD tail -f /dev/null
