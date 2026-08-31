use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Alien::Xrepo 0.08 {
    use Alien::Xmake;
    use JSON::PP;
    use Path::Tiny;
    use Config;
    #
    field $verbose : param //= 0;
    field $root    : param //= ();
    field $xmake = Alien::Xmake->new;

    # Pin the package repositories xmake fetches from. xmake consults the
    # XMAKE_BINARY_REPO / XMAKE_MAIN_REPO env vars and otherwise auto-selects
    # a mirror via net.fasturl; letting the caller pin them avoids reaching an
    # unreachable mirror (e.g. a proxy that can only tunnel github/gitlab).
    field $binary_repo : param //= ();
    field $main_repo   : param //= ();
    method blah ($msg) { return unless $verbose; say $msg; }
    #
    ADJUST {
        if ( defined $binary_repo && length $binary_repo ) {
            $ENV{XMAKE_BINARY_REPO} = $binary_repo;
        }
        if ( defined $main_repo && length $main_repo ) {
            $ENV{XMAKE_MAIN_REPO} = $main_repo;
        }
        if ($root) {
            my $p = path($root)->absolute;
            $p->mkpath;
            $ENV{XMAKE_CONFIGDIR}      = $p->child('.xmake')->stringify;
            $ENV{XMAKE_PKG_INSTALLDIR} = $p->child('packages')->stringify;
        }
    }

    class Alien::Xrepo::PackageInfo {
        use Path::Tiny;
        field $includedirs : param : reader;
        field $libfiles    : param : reader;
        field $license     : param : reader;
        field $linkdirs    : param : reader;
        field $links       : param : reader;
        field $shared      : param : reader;
        field $static      : param : reader;
        field $version     : param : reader;
        field $libpath     : param : reader //= ();
        field $bindirs     : param : reader //= [];
        field $kind        : param : reader //= 'library';
        field $installdir  : param : reader //= ();

        method find_header ($filename) {
            for my $dir (@$includedirs) {
                my $p = path($dir)->child($filename);
                return $p->stringify if $p->exists;
            }
            warn "Header '$filename' not found in package include directories:\n" . join( "\n", @$includedirs ) . "\n";
            return;
        }
        method bin_dir {$bindirs}

        method _data_printer ($ddp) {
            {   includedirs => $includedirs,
                libfiles    => $libfiles,
                license     => $license,
                linkdirs    => $linkdirs,
                links       => $links,
                shared      => $shared,
                static      => $static,
                version     => $version,
                libpath     => $libpath,
                bindirs     => $bindirs,
                kind        => $kind,
                installdir  => $installdir
            }
        }
    }

    method _run_capture (@cmd) {
        require Capture::Tiny;
        return Capture::Tiny::capture(
            sub {
                if ( $^O eq 'MSWin32' ) {
                    my $cmd_str = join( ' ', map { ( /\s/ && !/"/ ) ? qq{"$_"} : $_ } @cmd );
                    system($cmd_str);
                }
                else {
                    system(@cmd);
                }
            }
        );
    }
    #
    method install ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        my @args      = $self->_build_args( \%opts );
        say "[*] xrepo: ensuring $full_spec is installed..." if $verbose;
        my @install_cmd = $self->_xrepo_cmd( 'install', '-y', '-q', @args, $full_spec );
        my ( $out, $err, $exit ) = $self->_run_capture(@install_cmd);
        die "xrepo install failed for $full_spec:\n$err\n$out" if $exit != 0;
        my @fetch_cmd = $self->_xrepo_cmd( 'fetch', '--json', '-q', @args, $full_spec );
        my ( $json_out, $json_err, $json_exit ) = $self->_run_capture(@fetch_cmd);
        die "xrepo fetch failed: $json_err" if $json_exit != 0;
        $json_out =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;
        $json_out =~ s/\x1b\(B//g;
        if ( $json_out =~ m/(\[.*\]|\{.*\})/s ) { $json_out = $1; }
        my $data;
        try { $data = decode_json($json_out); }
        catch ($e) { die "Failed to decode xrepo JSON: $e\nOutput: $json_out"; }
        my $raw = ( ref $data eq 'ARRAY' ) ? $data->[0] : $data;
        return $self->_process_info($raw);
    }

    method uninstall ( $pkg_spec, %opts ) {
        my @args = $self->_build_args( \%opts );
        say "[*] xrepo: uninstalling $pkg_spec..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'remove', '-y', '-q', @args, $pkg_spec );
        $self->_run_capture(@cmd);
    }

    method search ($query) {
        say "[*] xrepo: searching for $query..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'search', '-q', $query );
        my ($out) = $self->_run_capture(@cmd);
        print $out if $verbose;
    }

    method clean () {
        say '[*] xrepo: cleaning cache...' if $verbose;
        my @cmd = $self->_xrepo_cmd( 'clean', '-y', '-q' );
        $self->_run_capture(@cmd);
    }
    #
    method add_repo ( $name, $url, $branch //= () ) {
        say "[*] xrepo: adding repo $name..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'add-repo', '-y', '-q', $name, $url );
        push @cmd, $branch if defined $branch;
        my ( $out, $err, $exit ) = $self->_run_capture(@cmd);
        die "xrepo add-repo failed:\n$err\n$out" if $exit != 0;
        return 1;
    }

    method remove_repo ($name) {
        say "[*] xrepo: removing repo $name..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'remove-repo', '-y', $name );

        # Capture so a non-zero exit / network failure doesn't spew Perl's
        # $! ("Can't spawn ...") to the caller's stdout.
        $self->_run_capture(@cmd);
        return;
    }

    method update_repo ( $name //= () ) {
        say '[*] xrepo: updating repositories...' if $verbose;
        my @cmd = ( 'update-repo', '-y' );
        push @cmd, $name if defined $name;
        my @run = $self->_xrepo_cmd(@cmd);

        # update-repo is best-effort; don't die and don't spew $! when the
        # remote mirror is unreachable (e.g. a proxy can't tunnel to it).
        $self->_run_capture(@run);
        return;
    }
    #
    method _xrepo_cmd (@cmd) {
        return $xmake->_xrepo_cmd(@cmd);
    }
    #
    method _build_args ($opts) {
        my @args;
        push @args, '-p', $opts->{plat} if $opts->{plat};
        push @args, '-a', $opts->{arch} if $opts->{arch};
        push @args, '-m', $opts->{mode} if $opts->{mode};
        push @args, '-k', ( $opts->{kind} // 'shared' );
        push @args, '--toolchain=' . $opts->{toolchain} if $opts->{toolchain};
        push @args, '--force'                           if $opts->{force};
        push @args, '--build'                           if $opts->{build};
        push @args, '--shallow'                         if $opts->{shallow};

        if ( my $c = $opts->{configs} ) {
            if ( ref $c eq 'HASH' ) {
                my $str = join( ',', map {"$_=$c->{$_}"} sort keys %$c );
                push @args, "--configs=$str";
            }
            else {
                push @args, "--configs=$c";
            }
        }
        if ( my $i = $opts->{includes} ) {
            push @args, '--includes=' . ( ref $i eq 'ARRAY' ? join( ',', @$i ) : $i );
        }
        return @args;
    }

    method _process_info ($info) {
        return () unless defined $info;
        my $kind       = $info->{kind} // 'library';
        my $installdir = $info->{artifacts} // $info->{installdir} // ();
        $installdir = $installdir->{installdir} if ref $installdir eq 'HASH';
        my $libfiles = $info->{libfiles}    // [];
        my $incdirs  = $info->{includedirs} // [];
        my $linkdirs = $info->{linkdirs}    // [];
        my $bindirs  = $info->{bindirs}     // [];

        if ( $kind eq 'binary' && !@$bindirs ) {
            if ( my $path_envs = $info->{envs}->{PATH} ) {
                @$bindirs = $installdir ? map { path($installdir)->child($_)->stringify } @$path_envs : @$path_envs;
            }
        }
        my $runtime_lib;
        if ( $^O eq 'MSWin32' ) {
            ($runtime_lib) = grep {/\.dll$/i} @$libfiles;
            unless ($runtime_lib) {
                my ($imp_lib) = grep {/\.lib$/i} @$libfiles;
                if ($imp_lib) {
                    my $lib_path = path($imp_lib);
                    my $basename = $lib_path->basename(qr/\.lib$/i);
                    my @search   = ( @$bindirs, $lib_path->parent->parent->child('bin'), $lib_path->parent->sibling('bin') );
                    for my $dir (@search) {
                        next unless -d $dir;
                        my $try = path($dir)->child("$basename.dll");
                        if ( $try->exists ) { $runtime_lib = $try->stringify; last; }
                        my ($fuzzy) = grep { /^$basename/i && /\.dll$/i } map { $_->basename } path($dir)->children;
                        if ($fuzzy) { $runtime_lib = path($dir)->child($fuzzy)->stringify; last; }
                    }
                }
            }
        }
        else {
            ($runtime_lib) = grep { /\.so(\.|-|\d|$)/ || /\.dylib$/i } @$libfiles;
        }
        $runtime_lib //= $libfiles->[0] if @$libfiles;
        return Alien::Xrepo::PackageInfo->new(
            includedirs => $incdirs,
            libfiles    => $libfiles,
            libpath     => $runtime_lib,
            linkdirs    => $linkdirs,
            links       => $info->{links}   // [],
            license     => $info->{license} // (),
            shared      => $info->{shared}  // 0,
            static      => $info->{static}  // 0,
            version     => $info->{version} // (),
            kind        => $kind,
            installdir  => $installdir,
            bindirs     => $bindirs
        );
    }
};
#
1;
