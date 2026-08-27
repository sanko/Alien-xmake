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
    #   3) build from source tarball (download + instructions only?)
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

    # The cosmocc/mac/linux*.x86_64 bundles are single self-contained binaries.
    # Install as $dist/xmake (or xmake.exe) and drop a sibling wrapper that
    # exposes xrepo (`xmake lua private.xrepo`).
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
            #!/bin/sh',
            dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
            exec "$dir/xmake" lua private.xrepo "$@"'
            ETC
        close $fh;
        chmod 0755, $wrapper;
    }

    sub _xmake_paths ($dist) {
        my $ext   = _is_win() ? '.exe' : '';
        my $xmake = File::Spec->catfile( $dist, 'xmake', 'xmake' . $ext );
        my $xrepo = File::Spec->catfile( $dist, 'xmake', 'xrepo' . ( _is_win() ? '.bat' : '' ) );
        $xmake = File::Spec->catfile( $dist, 'xmake' . $ext )                        unless -e $xmake;
        $xrepo = File::Spec->catfile( $dist, 'xrepo' . ( _is_win() ? '.bat' : '' ) ) unless -e $xrepo;
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

    # Install a local copy of xmake + xrepo into the share dir (where
    # Alien::Xmake will find it via dist_dir), then smoke test both, then let
    # Module::Build copy the share dir into blib (SUPER->ACTION_code).
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
            my $plan  = _choose_asset( $os, $arch, $version, $rel->{assets} ) or die "no asset strategy for $os/$arch\n";
            my $asset = _find_asset( $rel->{assets}, $plan->{pattern} )       or die "asset not found: $plan->{pattern}\n";

            if ( $plan->{strategy} eq 'zip' ) {
                _install_zip( $s, $dist, $asset );
            }
            elsif ( $plan->{strategy} eq 'bundle' ) {
                _install_bundle( $s, $dist, $asset );
            }
            else {
                my $src = File::Spec->catfile( $dist, $asset->{name} );
                _download( $s, $asset, $src );
                $s->log_warn(<<~"");
                    No prebuilt xmake binary for $os/$arch. Download the source to:
                        $src
                    and build manually (tar xf; ./configure && make).

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
