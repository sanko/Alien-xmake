use v5.40;
use experimental 'class';
class Alien::Xmake 0.08 {
    use File::Spec;
    use File::Basename qw[dirname];
    use JSON::PP       qw[decode_json];
    use File::ShareDir qw[dist_dir];
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

    method exe () {
        return $self->_quote_path( $self->_resolve_path );
    }

    method xrepo () {
        my $exe_path   = $self->_resolve_path;
        return $exe_path .  ' lua private.xrepo';
        #
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
        if ($windows) {

            # Capture::Tiny + system() on Windows returns a bogus exit code
            # because the spawned child inherits non-console pipe handles and
            # Perl misinterprets the result (spurious "Can't spawn ... Inappropriate
            # I/O control operation").  Use backticks with stderr merged so we
            # get a reliable exit code from $?
            my $cmd_str = join( ' ', map { ( /\s/ && !/"/ ) ? qq{"$_"} : $_ } @cmd );
            my $out = `$cmd_str 2>&1`;
            return ( $out, '', $? >> 8 );
        }
        require Capture::Tiny;
        return Capture::Tiny::capture( sub { system(@cmd) } );
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
        my @cmd = ( $self->_resolve_path, '--version' );
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
        return File::Spec->rel2abs($bin);
    }

    method _xrepo_cmd (@cmd) {
        my $exe = $self->_resolve_path;
        if ($windows) {
            # Catch file-not-found immediately instead of relying on Perl's broken shell-fallback
            if ( $self->install_type ne 'system' && !-e $exe ) {
                die "Alien::Xmake error: executable not found at '$exe'. Installation is corrupted.\n";
            }
            return ( $exe, 'lua', 'private.xrepo', @cmd );
        }
        return ( $self->xrepo, @cmd );
    }

    method _quote_path ($path) {
        return qq{"$path"} if $windows && $path =~ /\s/ && $path !~ /^"/;
        $path;
    }
} 1;
