use v5.40;
use experimental 'class';
class Alien::Xmake 0.08 {
    use File::Spec;
    use File::Basename qw[dirname];
    use JSON::PP       qw[decode_json];
    use File::ShareDir qw[dist_dir];
    use Config;
    #
    field $windows = $^O eq 'MSWin32';
    field $config : param //= sub {
        my $conf = { install_type => 'system' };
        try {
            require Alien::Xmake::ConfigData;
            $conf = { map { $_ => Alien::Xmake::ConfigData->config($_) } Alien::Xmake::ConfigData->config_names };
            if ( Alien::Xmake::ConfigData->can('bin') ) {
                $conf->{bin} = Alien::Xmake::ConfigData->bin;
            }
        }
        catch ($e) { }
        return $conf;
        }
        ->();
    field $dir = dist_dir('Alien-Xmake');
    method cflags ()       {''}
    method libs ()         {''}
    method dynamic_libs () { }
    method install_type () { $config->{install_type} }

    method bin_dir () {
        my $exe = $self->_resolve_path;
        return dirname($exe);
    }

    # Prepend the xmake/xrepo bin directory to PATH so the helpers can be
    # invoked by bare name instead of by an absolute Windows path. Passing a
    # full "D:\..." path to a child process launched from a git-bash runner
    # can fail with "Inappropriate I/O control operation"; a bare name that
    # CreateProcess resolves through PATH does not. Resolves the right
    # directory whether running from blib (ConfigData points into blib) or
    # from an installed share.
    method _ensure_path () {
        return unless $windows;
        my $dir    = $self->bin_dir;
        my $sep    = $Config{path_sep};
        return unless -d $dir;
        my $cur = $ENV{PATH} // '';
        return if $cur =~ m{(?:^|$sep)\Q$dir\E(?:$sep|$)}i;
        $ENV{PATH} = join $sep, $dir, $cur;
    }
    # Command word(s) used to launch xmake by bare name (after the bin dir is
    # on PATH). Used for --version resolution and any direct xmake invocation.
    method _run_base () {
        if ($windows) {
            $self->_ensure_path;
            return ('xmake');
        }
        return ($self->_resolve_path);
    }

    method exe () {
        return $self->_quote_path( $self->_resolve_path );
    }

    method xrepo () {
        my $exe_path   = $self->_resolve_path;
        my $parent     = dirname($exe_path);
        my $xrepo_name = 'xrepo' . ( $windows ? '.bat' : '' );
        my $try        = File::Spec->catfile( $parent, $xrepo_name );
        if ( -e $try ) {
            return $self->_quote_path($try);
        }
        if ( $config->{bin} && $self->install_type ne 'system' ) {
            my $conf_parent = dirname( $config->{bin} );
            my $target      = File::Spec->catfile( $conf_parent, $xrepo_name );
            return $self->_quote_path( File::Spec->rel2abs($target) );
        }
        return $xrepo_name;
    }

    method _run_capture (@cmd) {
        require Capture::Tiny;
        return Capture::Tiny::capture(
            sub {
                $self->_spawn(@cmd);
            }
        );
    }

    # On Win32, `system LIST` silently falls back to the shell (cmd.exe, or
    # bash/msys when launched from a git-bash runner), which dies with
    # "Inappropriate I/O control operation". The indirect-object form
    # `system { $prog } LIST` calls CreateProcess directly and never touches
    # the shell, so it works even when Perl itself is a child of msys bash.
    method _spawn (@cmd) {
        if ($windows) {
            my $prog = shift @cmd;
            system { $prog } $prog, @cmd;
        }
        else {
            system(@cmd);
        }
    }

    method pkg_config ($package) {
        my @xrepo = $self->_xrepo_cmd;
        my ( $out, $err, $exit ) = $self->_run_capture( @xrepo, 'install', '-y', $package );
        die "Alien::Xmake: Could not install package '$package'\n$err\n$out" if $exit != 0;
        my ( $cflags, undef, undef ) = $self->_run_capture( @xrepo, 'fetch', '--cflags',  $package );
        my ( $libs,   undef, undef ) = $self->_run_capture( @xrepo, 'fetch', '--ldflags', $package );
        return { cflags => $cflags, libs => $libs };
    }
    method version ()             { $self->install_type eq 'system' ? $self->_getver : $config->{version} }
    method build ()               { $self->_getbuild }
    method config ( $key //= () ) { defined $key ? $config->{$key} : $config }

    sub alien_helper () {
        { xmake => sub { __PACKAGE__->new->exe }, xrepo => sub { __PACKAGE__->new->xrepo } }
    }

    method _getver() {
        my ( $ver, undef ) = $self->_getver_build;
        "v$ver";
    }

    method _getbuild() {
        my ( undef, $build ) = $self->_getver_build;
        $build;
    }

    method _getver_build() {
        my @cmd = ( $self->_run_base, '--version' );
        state $out //= do {
            my ( $o, $e ) = $self->_run_capture(@cmd);
            $o;
        };
        return ( $1, $2 ) if $out =~ /xmake\s+v?(\d+\.\d+\.\d+)(?:\+(.+),)?/i;
        ( '0.0.0', () );
    }

    method _resolve_path () {
        my $bin = $config->{bin};

        # If system install, return exactly what was configured (could be bare 'xmake' or absolute path)
        if ( $self->install_type eq 'system' && defined $bin && $bin ne '' ) {
            return $bin;
        }

        # Try configured bin first
        if ( defined $bin && $bin ne '' && -e $bin ) {
            return File::Spec->rel2abs($bin);
        }

        # Try to locate in the share directory layout
        if ($dir) {
            my $ext        = $windows ? '.exe' : '';
            my @candidates = (
                File::Spec->catfile( $dir, 'xmake', 'xmake' . $ext ),
                File::Spec->catfile( $dir, 'xmake' . $ext ),
                File::Spec->catfile( $dir, 'xmake' ),
                File::Spec->catfile( $dir, 'bin', 'xmake' . $ext )
            );
            for my $c (@candidates) {
                return File::Spec->rel2abs($c) if defined $c && -e $c;
            }
        }

        # Fallback to the configured bin or default if everything fails
        $bin //= File::Spec->catfile( $dir // '.', 'xmake' . ( $windows ? '.exe' : '' ) );
        return File::Spec->canonpath( File::Spec->rel2abs($bin) );
    }

    method _xrepo_cmd (@cmd) {
        if ($windows) {
            $self->_ensure_path;

            # Invoke xmake by bare name via PATH rather than an absolute
            # D:\... path, which can fail to spawn under a git-bash runner.
            return ( 'xmake', 'lua', 'private.xrepo', @cmd );
        }
        return ( $self->xrepo, @cmd );
    }

    method _quote_path ($path) {
        return qq{"$path"} if $windows && $path =~ /\s/ && $path !~ /^"/;
        $path;
    }
} 1;
