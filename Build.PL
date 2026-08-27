use v5.40;
use Module::Build;
my $class = Module::Build->subclass( class => 'Alien::Xmake::Builder', code => <<'EOF' );
    use v5.40;
    $|++;
    use Config;
    use HTTP::Tiny;
    use JSON::PP       qw[decode_json];
    use File::Basename qw[dirname];
    use File::Copy;
    use File::Path qw[mkpath];
    use File::Spec;
    use IO::Uncompress::Unzip qw[$UnzipError];

    sub _http {
        CORE::state $http
            //= HTTP::Tiny->new( default_headers => { 'X-GitHub-Api-Version' => '2026-03-10', accept => 'application/vnd.github+json' } );
        $http;
    }
    sub _is_win { $^O =~ /^MSWin32$/i }

    # Map this OS + $Config{archname} to the names the upstream release CI uses.
    sub _detect_platform {
        my $os   = $^O;
        my $arch = lc $Config{archname} // '';
        $os = 'win'   if _is_win();
        $os = 'mac'   if $os eq 'darwin';
        $os = 'linux' if $os eq 'linux';
        my $cpu;
        if    ( $arch =~ /(?:x86_64|amd64|x64)/ ) { $cpu = 'x86_64' }
        elsif ( $arch =~ /(?:i[3-6]86|x86)/ )     { $cpu = 'x86' }
        elsif ( $arch =~ /(?:arm64|aarch64)/ )    { $cpu = 'arm64' }
        elsif ( $arch =~ /(?:armv7|armhf|arm)/ )  { $cpu = 'arm' }
        else                                      { $cpu = $arch }
        return ( $os, $cpu );
    }

    sub _latest_release ($tag) {
        my $url = 'https://api.github.com/repos/xmake-io/xmake/releases';
        $url .= '/tags/' . $tag if $tag;
        my $res = _http->get($url);
        die "github api failed: $res->{status} $res->{reason}\n" unless $res->{success};
        my $rel = decode_json( $res->{content} );
        return ( $rel, $rel->{tag_name} ) if $tag;
        my ($current) = grep { $_->{prerelease} == JSON::PP::false and $_->{draft} == JSON::PP::false } @$rel;
        die "no stable xmake release found\n" unless $current;
        return ( $current, $current->{tag_name} );
    }

    sub _find_asset ( $assets, $re ) {
        for my $a (@$assets) { return $a if $a->{name} =~ /$re/ }
        return;
    }

    # Pick what to fetch in this order
    #   1) dedicated prebuilt for (os, arch)
    #   2) cosmocc portable bundle
    #   3) build from source (configure/make/install)
    sub _choose_asset ( $os, $arch, $ver, $assets ) {
        my $has = sub { _find_asset( $assets, $_[0] ) };
        if ( $os eq 'win' ) {

            # Use the .zip (extracts a self-contained local xmake.exe +
            # xrepo, no system install). The .exe is an NSIS installer that prompts
            # for elevation/UAC, so we avoid it.
            return { strategy => 'zip', pattern => "xmake-v${ver}.win64.zip" } if $arch eq 'x86_64';
            return { strategy => 'zip', pattern => "xmake-v${ver}.win32.zip" } if $arch eq 'x86';
            return { strategy => 'zip', pattern => "xmake-v${ver}.arm64.zip" } if $arch eq 'arm64';
            return { strategy => 'zip', pattern => "xmake-v${ver}.win64.zip" };
        }
        if ( $os eq 'mac' ) {
            return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.macos.arm64" }  if $arch eq 'arm64';
            return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.macos.x86_64" } if $arch eq 'x86_64';
            return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.macos.x86_64" };
        }
        if ( $os eq 'linux' && $arch eq 'x86_64' && $has->("xmake-bundle-v${ver}.linux.x86_64") ) {
            return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.linux.x86_64" };
        }

        # everything else: cosmocc first, build from source only if unavailable
        return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.cosmocc" } if $has->("xmake-bundle-v${ver}.cosmocc");
        return { strategy => 'source', pattern => "xmake-v${ver}.tar.gz" };
    }

    sub _download ( $s, $asset, $dest ) {
        return if -e $dest && -s $dest;
        $s->log_verbose( "  download $asset->{name} (" . ( $asset->{size} // '?' ) . " bytes)\n" );
        my $res = _http->mirror( $asset->{browser_download_url}, $dest );
        die "download failed: $res->{status} $res->{reason}\n" unless $res->{success};
    }

    # The win*.zip archive contains a top-level xmake/ folder, so extracting
    # into $dist yields $dist/xmake/xmake.exe + $dist/xmake/xrepo.bat.
    sub _unzip ( $s, $zip, $out ) {
        my $uz    = IO::Uncompress::Unzip->new($zip) or die "can't open zip $zip: $UnzipError\n";
        my $count = 0;
        while ( my $status = $uz->nextStream() ) {
            my $name = $uz->getHeaderInfo()->{Name};
            next unless defined $name && length $name;
            $name =~ s{^[A-Za-z]:[/\\]+}{};
            $name =~ s{^[/\\]+}{};
            $name =~ s{(?:\.\./|\.\.\\)}{}g;
            next unless length $name;
            my $target = File::Spec->catfile( $out, grep {length} split m{[/\\]}, $name );
            if ( $name =~ m{[/\\]$} ) { mkpath($target); next; }
            my $parent = dirname($target);
            mkpath($parent) unless -d $parent;
            open my $fh, '>:raw', $target or die "can't write $target: $!\n";
            my $buf;
            while ( ( my $rc = $uz->read( $buf, 1_048_576 ) ) > 0 ) { print {$fh} $buf; }
            close $fh;
            $count++;
        }
        $s->log_verbose( "  extracted $count files -> " . File::Spec->catdir( $out, 'xmake' ) . "\n" );
    }

    # The cosmocc/mac/linux*.x86_64 bundles are single self contained binaries. Install as
    # $dist/xmake(.exe) and drop a sibling wrapper that exposes xrepo (`xmake lua private.xrepo`)
    sub _install_bundle ( $s, $dist, $asset ) {
        my $exe     = File::Spec->catfile( $dist, _is_win() ? 'xmake.exe' : 'xmake' );
        my $wrapper = File::Spec->catfile( $dist, _is_win() ? 'xrepo.bat' : 'xrepo' );
        return if -e $exe && -s $exe && -e $wrapper;
        _download( $s, $asset, $exe );
        chmod 0755, $exe;
        open my $fh, '>:raw', $wrapper or die "can't write $wrapper: $!\n";
        print {$fh} _is_win() ? <<~'WIN' : <<~'ETC';
            @echo off
            "%~dp0xmake.exe" lua private.xrepo %*
            WIN
            #!/bin/sh
            dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
            exec "$dir/xmake" lua private.xrepo "$@"
            ETC
        close $fh;
        chmod 0755, $wrapper;
    }

    # No prebuilt binary for this platform so we replicate the official installer and build from source.
    sub _install_source ( $s, $dist, $version, $rel ) {
        my $bin  = File::Spec->catfile( $dist, 'bin', _is_win() ? 'xmake.exe' : 'xmake' );
        my $wrap = File::Spec->catfile( $dist, 'bin', _is_win() ? 'xrepo.bat' : 'xrepo' );
        return if -e $bin && -e $wrap;
        $s->log_warn("Alien::Xmake: no prebuilt binary for this platform; building xmake $version from source (get.sh path)\n");
        die "xmake source build needs 'make' on PATH\n" unless _have_cmd('make');
        my $tmp = File::Spec->catdir( File::Spec->tmpdir, 'xmake-getter-' . $$ );
        File::Path::remove_tree($tmp) if -d $tmp;
        mkpath($tmp);

        # Prefer an explicit .tar.gz asset on the release, else GitHub's auto-generated source archive (tarball_url redirects to it).
        my $asset = _find_asset( $rel->{assets}, '\.tar\.gz$' );
        my $url   = $asset ? $asset->{browser_download_url} : $rel->{tarball_url};
        die "no source URL for xmake v$version\n" unless $url;
        my $name = ( $asset ? $asset->{name} : "xmake-v$version.tar.gz" );
        my $tgz  = File::Spec->catfile( $tmp, $name );
        _download( $s, { browser_download_url => $url, name => $name }, $tgz );
        _untargz( $s, $tgz, $tmp );

        # GitHub archives unpack to a single top-level xmake-*/ directory whose name includes the commit sha; auto-detect it
        opendir my $dh, $tmp or die "can't read $tmp: $!\n";
        my ($top) = grep { !/^\.\.?$/ && -d File::Spec->catdir( $tmp, $_ ) } readdir $dh;
        closedir $dh;
        my $src = $top ? File::Spec->catdir( $tmp, $top ) : undef;
        die "source archive did not unpack as expected\n" unless $src;
        my $cd = "cd '$src'";
        $s->_run_or_die("$cd && ./configure") if -f File::Spec->catfile( $src, 'configure' );
        $s->_run_or_die("$cd && make");
        my $qdist = $dist;
        $qdist =~ s/'/'\\''/g;
        $s->_run_or_die("$cd && make install PREFIX='$qdist'");
        File::Path::remove_tree($tmp);
        die "source build produced no xmake at $bin\n" unless -e $bin;
        open my $fh, '>:raw', $wrap or die "can't write $wrap: $!\n";
        print {$fh} _is_win() ? <<~'WIN' : <<~'ETC';
            @echo off
            "%~dp0xmake.exe" lua private.xrepo %*
            WIN
            #!/bin/sh
            dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
            exec "$dir/xmake" lua private.xrepo "$@"
            ETC
        close $fh;
        chmod 0755, $wrap;
    }

    sub _untargz ( $s, $tgz, $out ) {
        require IO::Uncompress::Gunzip;
        require Archive::Tar;
        my $raw;
        die "can't gunzip $tgz\n" unless IO::Uncompress::Gunzip::gunzip( $tgz => \$raw );
        my $at = Archive::Tar->new;
        open my $rfh, '<', \$raw or die "can't open tar stream: $!\n";
        die "can't read tar from $tgz\n" unless $at->read($rfh);
        mkpath($out)                     unless -d $out;
        my $count = 0;

        for my $e ( $at->get_files ) {
            my $n = $e->full_path or next;
            next if $e->is_dir;
            my $target = File::Spec->catfile( $out, grep {length} split m{/}, $n );
            my $parent = dirname($target);
            mkpath($parent) unless -d $parent;
            open my $fh, '>:raw', $target or die "can't write $target: $!\n";
            print {$fh} $e->get_content;
            close $fh;
            $count++;
        }
        $s->log_verbose("  extracted $count files -> $out\n");
    }

    sub _run_or_die ( $s, $cmd ) {
        if ( ref $cmd eq 'ARRAY' ) {
            $s->log_verbose( '  $ ' . join( ' ', @$cmd ) . "\n" );
            die "command failed\n" if system(@$cmd) != 0;
        }
        else {
            $s->log_verbose("  \$ $cmd\n");
            die "command failed: $cmd\n" if system($cmd) != 0;
        }
    }

    sub _have_cmd ($name) {
        if ( _is_win() ) { return system( 1, 'where', $name ) == 0 }
        return system( 1, 'command', '-v', $name ) == 0;
    }

    sub _xmake_paths ($dist) {
        my $ext   = _is_win() ? '.exe' : '';
        my $xmake = File::Spec->catfile( $dist, 'xmake', 'xmake' . $ext );
        my $xrepo = File::Spec->catfile( $dist, 'xmake', 'xrepo' . ( _is_win() ? '.bat' : '' ) );
        $xmake = File::Spec->catfile( $dist, 'xmake' . $ext )                        unless -e $xmake;
        $xrepo = File::Spec->catfile( $dist, 'xrepo' . ( _is_win() ? '.bat' : '' ) ) unless -e $xrepo;

        # get.sh source-build layout: $dist/bin/xmake + $dist/bin/xrepo
        $xmake = File::Spec->catfile( $dist, 'bin', 'xmake' . $ext )                        unless -e $xmake;
        $xrepo = File::Spec->catfile( $dist, 'bin', 'xrepo' . ( _is_win() ? '.bat' : '' ) ) unless -e $xrepo;
        return ( $xmake, $xrepo );
    }

    sub _smoke_test ( $s, $dist ) {
        my ( $xmake, $xrepo ) = _xmake_paths($dist);
        $s->log_verbose("\nAlien::Xmake: smoke testing installed binaries\n");
        my $ok = 0;
        for my $bin ( $xmake, $xrepo ) {
            next unless -e $bin;
            my $rc;
            if ( _is_win() && $bin =~ /\.bat$/i ) {
                $rc = system( 1, 'cmd.exe', '/c', qq{"$bin" --version} );
            }
            else {
                $rc = system( $bin, '--version' );
            }
            $ok = 1 if $rc == 0;
            $s->log_verbose( "  $bin --version => " . ( $rc == 0 ? "ok\n" : "FAIL (rc=$rc)\n" ) );
        }
        $s->log_warn("Alien::Xmake: could not run local xmake/xrepo -- tests may fail\n") unless $ok;
    }

    # Install a local copy of xmake + xrepo into the share dir (where Alien::Xmake will find it via
    # dist_dir), then smoke test both, then let Module::Build copy the share dir into blib.
    sub ACTION_code ($s) {
        $s->log_verbose("Alien::Xmake: ACTION_code\n");
        my $dist = $s->share_dir->{dist};
        $dist = $dist->[0] if ref $dist eq 'ARRAY';
        $dist = File::Spec->rel2abs($dist);
        mkpath($dist) unless -d $dist;
        eval {
            my ( $os, $arch ) = _detect_platform();
            if ( $ENV{PLATFORM} && $ENV{PLATFORM} =~ /^([^,]+),(.+)$/ ) { ( $os, $arch ) = ( lc $1, lc $2 ) }
            $s->log_verbose("  platform: $os / $arch\n");
            my ( $rel, $version ) = _latest_release( $ENV{XMAKE_RELEASE} );
            $version =~ s/^v//;
            $s->log_verbose("  release: $version\n");
            my $plan = _choose_asset( $os, $arch, $version, $rel->{assets} ) or die "no asset strategy for $os/$arch\n";
            if ( $plan->{strategy} eq 'source' ) {
                _install_source( $s, $dist, $version, $rel );
            }
            else {
                my $asset = _find_asset( $rel->{assets}, $plan->{pattern} ) or die "asset not found: $plan->{pattern}\n";
                $plan->{strategy} eq 'zip' ? _install_zip( $s, $dist, $asset ) : _install_bundle( $s, $dist, $asset );
            }
            _smoke_test( $s, $dist );
        };
        $s->log_warn( 'Alien::Xmake: local install skipped/failed: ' . $@ ) if $@;
        $s->SUPER::ACTION_code();
    }

    sub _install_zip ( $s, $dist, $asset ) {
        my $bin = File::Spec->catfile( $dist, 'xmake', 'xmake' . _is_win() ? '.exe' : 'xmake' );
        return if -e $bin && -s $bin;
        my $zip = File::Spec->catfile( $dist, $asset->{name} );
        $s->add_to_cleanup($zip);
        _download( $s, $asset, $zip );
        _unzip( $s, $zip, $dist );
    }
EOF

my $build = $class->new(
    module_name => 'Alien::Xmake',
    license     => 'artistic_2',
    dist_author => 'Sanko Robinson',
    requires    => { Carp => 0 },
    share_dir   => 'share'
);
$build->create_build_script;
