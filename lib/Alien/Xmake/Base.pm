use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Alien::Xmake::Base {
    use Alien::Xrepo;
    use Path::Tiny;
    #
    field $package_name       : param = undef;
    field $version_constraint : param = undef;
    field $root               : param = undef;
    field $verbose            : param = 0;
    field $repo;
    field $info;
    #
    method _default_package_name {undef}
    #
    ADJUST {
        $package_name //= $self->_default_package_name;
        die "package_name is required" unless $package_name;

        # Attempt to populate $info from generated ConfigData
        my $child_class  = ref($self);
        my $config_class = "${child_class}::ConfigData";
        try {
            my $file = $config_class =~ s|::|/|gr . '.pm';
            require $file;
            if ( $config_class->can('package') ) {
                my $c = $config_class->package($package_name);
                if ($c) {
                    $info = Alien::Xrepo::PackageInfo->new(
                        version     => $c->{version},
                        libpath     => $c->{libpath},
                        includedirs => $c->{includedirs},
                        linkdirs    => $c->{linkdirs},
                        links       => $c->{links},
                        kind        => $c->{kind},
                        installdir  => $c->{installdir},
                        bindirs     => $c->{bindirs},
                    );
                }
            }
        }
        catch ($e) {

            # Not installed or utilizing dynamic runtime fetch fallback
        }

        # Setup repo engine
        $repo = Alien::Xrepo->new( root => $root, verbose => $verbose );
    }

    method install (%opts) {
        $info = $repo->install( $package_name, $version_constraint, %opts );
        return $info;
    }

    method upgrade (%opts) {
        $repo->update_repo();
        return $self->install(%opts);
    }
    method package_info () {$info}

    # Delegation methods
    method libpath () { $info ? $info->libpath : undef }
    method bin_dir () { $info ? $info->bin_dir : [] }
    method version () { $info ? $info->version : undef }
    method kind ()    { $info ? $info->kind    : undef }

    method cflags () {
        return '' unless $info;
        return join ' ', map {"-I$_"} @{ $info->includedirs };
    }

    method libs () {
        return '' unless $info;
        my $libs = join ' ', map {"-L$_"} @{ $info->linkdirs // [] };
        $libs .= ' ' . join ' ', map {"-l$_"} @{ $info->links // [] };
        return $libs;
    }

    method find_header ($filename) {
        return $info ? $info->find_header($filename) : undef;
    }

    method wrap (%opts) {
        require Affix::Wrap;
        return Affix::Wrap->new(
            project_files => [ $self->find_header( $opts{header} // ( $package_name . '.h' ) ) ],
            include_dirs  => $info->includedirs,
            %opts
        )->wrap( $self->libpath );
    }

    class Alien::Xmake::Base::Builder {
        use CPAN::Meta;
        use ExtUtils::Install qw[pm_to_blib install];
        use ExtUtils::InstallPaths;
        use JSON::PP;
        use Config;
        use Path::Tiny        qw[path cwd];
        use ExtUtils::Helpers qw[make_executable split_like_shell detildefy];
        use Data::Dumper;
        use Alien::Xrepo;

        # Configuration
        field $meta   : reader //= CPAN::Meta->load_file('META.json');
        field $action : param  //= 'build';
        field $target_config //= ();    # e.g. 'lib/Alien/lsquic/ConfigData.pm'

        # Params to Build script
        field $install_base  : param    //= '';
        field $installdirs   : param    //= '';
        field $uninst        : param    //= 0;
        field $install_paths : param    //= ExtUtils::InstallPaths->new( dist_name => $meta->name );
        field $verbose       : param(v) //= 0;
        field $dry_run       : param    //= 0;
        field $pureperl      : param    //= 0;
        field $jobs          : param    //= 1;
        field $destdir       : param    //= '';
        field $prefix        : param    //= '';
        ADJUST {
            -e 'META.json' or die "No META information provided\n";
            $target_config //= path('lib')->child( split /-/, $meta->name )->child('ConfigData.pm')->stringify;
        }

        method Build_PL() {
            say sprintf 'Creating new Build script for %s %s', $meta->name, $meta->version;
            my $inc_str = join( ' ', map {"-I$_"} @INC );
            $self->write_file( 'Build', sprintf <<'', $^X, $inc_str, ref($self), ref($self) );
#!%s %s
use lib 'builder', 'lib';
use %s;
%s->new( @ARGV && $ARGV[0] =~ /\A\w+\z/ ? ( action => shift @ARGV ) : (),
    map { /^--/ ? ( shift(@ARGV) =~ s[^--][]r => 1 ) : /^-/ ? ( shift(@ARGV) =~ s[^-][]r => shift @ARGV ) : () } @ARGV )->Build();

            make_executable('Build');
            my @env = defined $ENV{PERL_MB_OPT} ? split_like_shell( $ENV{PERL_MB_OPT} ) : ();
            $self->write_file( '_build_params', encode_json( [ \@env, \@ARGV ] ) );
            $meta->save(@$_) for ['MYMETA.json'];
        }

        method ACTION_build () {
            say "Building " . $meta->name . "...";

            # Prepare blib
            path('blib/lib')->mkpath;
            path('blib/arch')->mkpath;
            path('blib/script')->mkpath;
            path('blib/bin')->mkpath;

            # Copy Libs
            $self->_copy_libs();

            # Alien Logic: Install packages defined in META.json
            my $config_data = $self->_resolve_alien();

            # Generate ConfigData.pm
            $self->_write_config_data($config_data);
            say 'Build complete';
        }

        method ACTION_install () {
            say 'Installing...';
            require ExtUtils::Install;
            ExtUtils::Install::install( { 'blib/lib' => $install_paths->install_path('lib'), 'blib/arch' => $install_paths->install_path('arch') },
                1, 0, 0 );
        }

        method ACTION_clean () {
            say 'Cleaning...';
            path('blib')->remove_tree;
            path('_build_params')->remove;
            path('Build')->remove;
            path('MYMETA.json')->remove;
            path('MYMETA.yml')->remove;
        }

        method ACTION_test () {
            $self->ACTION_build();
            say 'Running tests...';
            require Test::Harness;
            my @tests = glob('t/*.t');
            Test::Harness::runtests(@tests) if @tests;
        }

        method _copy_libs () {
            my $src_root = path('lib');
            return unless $src_root->exists;
            my $iter = $src_root->iterator( { recurse => 1 } );
            while ( my $file = $iter->() ) {
                next unless $file->is_file;
                my $rel = $file->relative($src_root);
                next if $rel =~ m{(^|/)\.};
                my $dest = path('blib/lib')->child($rel);
                $dest->parent->mkpath;
                $file->copy($dest) or die "Copy failed: $!";
            }
        }

        method _resolve_alien () {
            my $x_alien  = $meta->custom('x_alien_xmake') // {};
            my $packages = $x_alien->{packages}           // {};
            my $options  = $x_alien->{options}            // {};

            # Create the standard File::ShareDir path in the build directory
            my $dist_name = $meta->name;
            my $share_dir = path('blib')->child( 'lib', 'auto', 'share', 'dist', $dist_name )->absolute;
            $share_dir->mkpath;

            # Force xrepo to use this share directory
            my $repo = Alien::Xrepo->new( verbose => $verbose, root => $share_dir->stringify );
            my %results;

            # Helper to make paths relative to the share directory
            my $make_rel = sub ($path) {
                return undef unless defined $path;
                my $p = path($path);
                return $p->relative($share_dir)->stringify if $share_dir->subsumes($p);
                return $p->stringify;
            };
            for my $pkg ( sort keys %$packages ) {
                my $ver = $packages->{$pkg};
                say "Installing $pkg ($ver) via Xrepo...";
                my $info = $repo->install( $pkg, $ver, %$options );

                # Extract data and enforce relative paths
                $results{$pkg} = {
                    version     => $info->version,
                    kind        => $info->kind,
                    links       => $info->links,
                    libpath     => $make_rel->( $info->libpath ),
                    installdir  => $make_rel->( $info->installdir ),
                    includedirs => [ map { $make_rel->($_) } @{ $info->includedirs // [] } ],
                    linkdirs    => [ map { $make_rel->($_) } @{ $info->linkdirs    // [] } ],
                    bindirs     => [ map { $make_rel->($_) } @{ $info->bindirs     // [] } ],
                };
            }
            return \%results;
        }

        method _write_config_data ($data) {
            my $dest = path('blib')->child($target_config);
            $dest->parent->mkpath;
            my $dumper = Data::Dumper->new( [$data], ['conf'] );
            $dumper->Indent(1)->Terse(1)->Sortkeys(1);
            my $package = $meta->name;
            $package =~ s/-/::/g;
            $package .= "::ConfigData";

            # Calculate depth to properly fallback to parent directories when uninstalled
            my $depth   = scalar( split( /::/, $package ) );
            my $content = sprintf <<~'PERL', $package, $meta->name, $depth, $dumper->Dump;
        package %s {
            use v5.40;
            use File::ShareDir qw[dist_dir];
            use Path::Tiny qw[path];

            my $dist_name = '%s';
            my $depth     = %d;
            my $config    = %s;

            # Resolve share dir safely
            my $share_dir;
            try {
                $share_dir = path( dist_dir($dist_name) );
            } catch ($e) {
                # Fallback for testing from uninstalled 'blib'
                $share_dir = path(__FILE__)->parent($depth)->child('auto', 'share', 'dist', $dist_name);
            }

            # Re-absolutize dynamically
            my $make_abs = sub ($p) {
                return undef unless defined $p;
                return $p if path($p)->is_absolute;
                return $share_dir->child($p)->stringify;
            };

            sub config ($class, $key //= ()) {
                state $expanded = do {
                    my $copy = {};
                    for my $pkg (keys %%$config) {
                        my $c = $config->{$pkg};
                        $copy->{$pkg} = {
                            %%$c,
                            libpath     => $make_abs->($c->{libpath}),
                            installdir  => $make_abs->($c->{installdir}),
                            includedirs =>[ map { $make_abs->($_) } @{ $c->{includedirs} // [] } ],
                            linkdirs    =>[ map { $make_abs->($_) } @{ $c->{linkdirs} // [] } ],
                            bindirs     =>[ map { $make_abs->($_) } @{ $c->{bindirs} // [] } ],
                        };
                    }
                    $copy;
                };
                defined $key ? $expanded->{$key} : $expanded;
            }

            sub config_names ($class) { sort keys %%{ __PACKAGE__->config } }

            sub package ($class, $pkg = undef) {
                $pkg //= (keys %%$config)[0];
                return __PACKAGE__->config->{$pkg};
            }
        };
        1;
        PERL
            $dest->spew_utf8($content);
            say "Generated $dest";
        }

        method write_file( $filename, $content ) {
            path($filename)->spew_raw($content);
        }

        method Build(@args) {
            my $method = $self->can( 'ACTION_' . $action );
            $method // die "No such action '$action'\n";
            exit !$method->($self);
        }
    }
}
1;
__END__

=pod

=head1 NAME

Alien::Xmake::Base - Base class for Alien::* distributions using Xmake/Xrepo

=head1 SYNOPSIS

    use v5.40;
    use feature 'class';
    use Alien::Xmake::Base;

    class Alien::lsquic :isa(Alien::Xmake::Base) {
        method _default_package_name { 'lsquic' }
    }

    # In a script:
    my $alien = Alien::lsquic->new;
    $alien->install;
    say $alien->libpath;

=head1 DESCRIPTION

This base class simplifies the creation of C<Alien::*> modules that use C<xrepo> to manage their dependencies.

It leverages Perl 5.40's C<class> features and C<Alien::Xrepo> to provide a consistent interface for installing,
locating, and using native libraries and executables.

=head1 METHODS

=head2 C<install( %options )>

Installs the package via C<xrepo>. Accepts the same options as C<Alien::Xrepo::install>.

=head2 C<upgrade( %options )>

Updates the local C<xrepo> repositories and then calls C<install()>. This is useful for ensuring the latest version of
a library or executable is installed.

=head2 C<libpath( )>

Returns the absolute path to the main shared library.

=head2 C<bin_dir( )>

Returns an array reference of directories containing executables.

=head2 C<cflags( )>

Returns a string of C< -I... > flags for the compiler.

=head2 C<libs( )>

Returns a string of C< -L... -l... > flags for the linker.

=head2 C<version( )>

Returns the version of the installed package.

=head2 C<kind( )>

Returns C<library> or C<binary>.

=head2 C<find_header( $filename )>

Returns the absolute path to a specific header file if found in the package's include directories.

=head2 C<wrap( %options )>

Integrates with L<Affix::Wrap> to automatically generate FFI bindings.

    $alien->wrap( header => 'lsquic.h' );

=head1 SUBCLASSING

When creating a new C<Alien::*> module, inherit from this class and override C<_default_package_name>.

    use v5.40;
    use feature 'class';
    use Alien::Xmake::Base;

    class Alien::MyLib :isa(Alien::Xmake::Base) {
        method _default_package_name { 'mylib' }
    }

=cut
