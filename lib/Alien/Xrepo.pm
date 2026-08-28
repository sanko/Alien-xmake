use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Alien::Xrepo 0.08 {
    use Alien::Xmake;
    use JSON::PP;
    use Path::Tiny;
    use Config;
    use Capture::Tiny qw[capture];
    #
    field $verbose : param //= 0;
    field $root    : param //= ();
    field $xmake = Alien::Xmake->new;
    method blah ($msg) { return unless $verbose; say $msg; }
    #
    ADJUST {
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
    #
    method install ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        my @args      = $self->_build_args( \%opts );
        say "[*] xrepo: ensuring $full_spec is installed..." if $verbose;
        my @install_cmd = $self->_xrepo_cmd( 'install', '-y', '-q', @args, $full_spec );
        system( { $install_cmd[0] } @install_cmd ) == 0 or die "xrepo install failed for $full_spec: $!";
        my @fetch_cmd = $self->_xrepo_cmd( 'fetch', '--json', '-q', @args, $full_spec );
        my ( $json_out, $json_err, $json_exit ) = capture { system( { $fetch_cmd[0] } @fetch_cmd ) };
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
        system( { $cmd[0] } @cmd );
    }

    method search ($query) {
        say "[*] xrepo: searching for $query..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'search', '-q', $query );
        system( { $cmd[0] } @cmd );
    }

    method clean () {
        say '[*] xrepo: cleaning cache...' if $verbose;
        my @cmd = $self->_xrepo_cmd( 'clean', '-y', '-q' );
        system( { $cmd[0] } @cmd );
    }
    #
    method add_repo ( $name, $url, $branch //= () ) {
        say "[*] xrepo: adding repo $name..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'add-repo', '-y', '-q', $name, $url );
        push @cmd, $branch if defined $branch;
        my ( $out, $err, $exit ) = capture { system( { $cmd[0] } @cmd ) };
        die "xrepo add-repo failed:\n$err" if $exit != 0;
        return 1;
    }

    method remove_repo ($name) {
        say "[*] xrepo: removing repo $name..." if $verbose;
        my @cmd = $self->_xrepo_cmd( 'remove-repo', '-y', $name );
        system( { $cmd[0] } @cmd );
    }

    method update_repo ( $name //= () ) {
        say '[*] xrepo: updating repositories...' if $verbose;
        my @cmd = ( 'update-repo', '-y' );
        push @cmd, $name if defined $name;
        my @run = $self->_xrepo_cmd(@cmd);
        system( { $run[0] } @run );
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
