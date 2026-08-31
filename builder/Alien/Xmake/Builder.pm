# Based on Module::Build::Tiny which is copyright (c) 2011 by Leon Timmermans, David Golden.
# Module::Build::Tiny is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
use v5.40;
use feature 'class';
no warnings 'experimental::class';

# https://docs.github.com/en/rest/releases/releases?apiVersion=2026-03-10#list-releases--code-samples
# https://docs.github.com/en/rest/releases/assets?apiVersion=2026-03-10
use v5.40;
use experimental 'class';
class    #
    Alien::Xmake::Builder {
    $|++;
    use Config;
    use CPAN::Meta;
    use Exporter 5.57 qw[import];
    use ExtUtils::Config 0.003;
    use ExtUtils::Helpers 0.020 qw[make_executable split_like_shell man1_pagename man3_pagename detildefy];
    use ExtUtils::Install qw[pm_to_blib install];
    use ExtUtils::InstallPaths 0.002;
    use Archive::Tar;
    use Cwd qw[cwd];
    use Data::Dumper;
    use File::Basename qw[basename dirname];
    use File::Copy     qw[copy];
    use File::Find     ();
    use File::Path     qw[mkpath rmtree];
    use File::Spec;
    use File::Spec::Functions qw[catfile catdir rel2abs abs2rel splitdir curdir];
    use Getopt::Long 2.36 qw[GetOptionsFromArray];
    use HTTP::Tiny;
    use IO::Uncompress::Gunzip;
    use IO::Uncompress::Unzip qw[$UnzipError];
    use JSON::PP 2 qw[encode_json decode_json];
    use version;
    #
    field $owner = 'xmake-io';
    field $repo  = 'xmake';
    #
    field $dryrun = 0;     # bool
    field $force  = 0;     # bool: skip system/reuse detection and reinstall
    field $tag    = '';    # optional explicit tag, default latest

    #
    field $http = do {
        my %headers = ( 'X-GitHub-Api-Version' => '2026-03-10', accept => 'application/vnd.github+json' );
        my $token   = $ENV{GITHUB_TOKEN} // $ENV{GH_TOKEN};
        $headers{Authorization} = "Bearer $token" if $token && length $token;
        HTTP::Tiny->new( default_headers => \%headers );
    };
    #
    field $os   = $^O;
    field $arch = 'x64';    # We figure it out later
    field $asset;
    field $rel;
    field $version;
    ADJUST {
        ( $os, $arch ) = $self->detect_platform();
        if ( $ENV{PLATFORM} && $ENV{PLATFORM} =~ /^([^,]+),(.+)$/ ) { ( $os, $arch ) = ( lc $1, lc $2 ) }
        say "platform: $os / $arch";
        ( $rel, $version ) = $self->latest_release($tag);
        $version =~ s/^v//;
        say "release: $version";
    }

    sub write_file ( $filename, $content ) {
        open my $fh, '>', $filename or die "Could not open $filename: $!\n";
        print $fh $content;
    }

    sub read_file ($filename) {
        open my $fh, '<', $filename or die "Could not open $filename: $!\n";
        return do { local $/; <$fh> };
    }

    sub get_meta {
        my ($metafile) = grep { -e $_ } qw[META.json META.yml] or die "No META information provided\n";
        return CPAN::Meta->load_file($metafile);
    }

    sub manify ( $input_file, $output_file, $section, $opts ) {
        return if -e $output_file && -M $input_file <= -M $output_file;
        my $dirname = dirname($output_file);
        mkpath( $dirname, $opts->{verbose} ) if not -d $dirname;
        require Pod::Man;
        Pod::Man->new( section => $section )->parse_from_file( $input_file, $output_file );
        print "Manifying $output_file\n" if $opts->{verbose} && $opts->{verbose} > 0;
        return;
    }

    sub process_xs {
        my ( $source, $options, $c_files ) = @_;
        die "Can't build xs files under --pureperl-only\n" if $options->{'pureperl-only'};
        my ( undef, @parts ) = splitdir( dirname($source) );
        push @parts, my $file_base = basename( $source, '.xs' );
        my $archdir = catdir( qw[blib arch auto], @parts );
        my $tempdir = 'temp';
        my $c_file  = catfile( $tempdir, "$file_base.c" );
        require ExtUtils::ParseXS;
        mkpath( $tempdir, $options->{verbose}, oct '755' );
        ExtUtils::ParseXS::process_file( filename => $source, prototypes => 0, output => $c_file );
        my $version = $options->{meta}->version;
        require ExtUtils::CBuilder;
        my $builder = ExtUtils::CBuilder->new( config => $options->{config}->values_set );
        my @objects = $builder->compile(
            source               => $c_file,
            defines              => { VERSION => qq/"$version"/, XS_VERSION => qq/"$version"/ },
            include_dirs         => [ curdir, 'include', 'src', dirname($source) ],
            extra_compiler_flags => $options->{extra_compiler_flags}
        );
        my $o = $options->{config}->get('_o');

        for my $c_source ( @{$c_files} ) {
            my $o_file = catfile( $tempdir, basename( $c_source, '.c' ) . $o );
            push @objects,
                $builder->compile(
                source               => $c_source,
                include_dirs         => [ curdir, 'include', 'src', dirname($c_source) ],
                extra_compiler_flags => $options->{extra_compiler_flags}
                );
        }
        require DynaLoader;
        my $mod2fname = defined &DynaLoader::mod2fname ? \&DynaLoader::mod2fname : sub { return $_[0][-1] };
        mkpath( $archdir, $options->{verbose}, oct '755' ) unless -d $archdir;
        my $lib_file = catfile( $archdir, $mod2fname->( \@parts ) . '.' . $options->{config}->get('dlext') );
        return $builder->link(
            objects            => \@objects,
            lib_file           => $lib_file,
            extra_linker_flags => $options->{extra_linker_flags},
            module_name        => join '::',
            @parts
        );
    }

    sub find {
        my ( $pattern, $dir ) = @_;
        my @ret;
        File::Find::find( sub { push @ret, $File::Find::name if /$pattern/ && -f }, $dir ) if -d $dir;
        return @ret;
    }

    sub contains_pod {
        my ($file) = @_;
        return unless -T $file;
        return read_file($file) =~ /^\=(?:head|pod|item)/m;
    }
    my %actions = (
        build => method(%opt) {
            my $install = $self->get_installer(%opt);
            for my $pl_file ( find( qr/\.PL$/, 'lib' ) ) {
                ( my $pm = $pl_file ) =~ s/\.PL$//;
                system $^X, $pl_file, $pm and die "$pl_file returned $?\n";
            }
            my %modules = map { $_ => catfile( 'blib', $_ ) } find( qr/\.pm$/,  'lib' );
            my %docs    = map { $_ => catfile( 'blib', $_ ) } find( qr/\.pod$/, 'lib' );
            my %scripts = map { $_ => catfile( 'blib', $_ ) } find( qr/(?:)/,   'script' );
            my %sdocs   = map { $_ => delete $scripts{$_} } grep {/.pod$/} keys %scripts;
            my %dist_shared
                = map { $_ => catfile( qw/blib lib auto share dist/, $opt{meta}->name, abs2rel( $_, 'share' ) ) } find( qr/(?:)/, 'share' );
            my %module_shared
                = map { $_ => catfile( qw/blib lib auto share module/, abs2rel( $_, 'module-share' ) ) } find( qr/(?:)/, 'module-share' );
            pm_to_blib( { %modules, %docs, %scripts, %dist_shared, %module_shared }, catdir(qw[blib lib auto]) );
            make_executable($_) for values %scripts;
            mkpath( catdir(qw/blib arch/), $opt{verbose} );

            if ( $opt{install_paths}->install_destination('bindoc') && $opt{install_paths}->is_default_installable('bindoc') ) {
                my $section = $opt{config}->get('man1ext');
                for my $input ( keys %scripts, keys %sdocs ) {
                    next unless contains_pod($input);
                    my $output = catfile( 'blib', 'bindoc', man1_pagename($input) );
                    manify( $input, $output, $section, \%opt );
                }
            }
            if ( $opt{install_paths}->install_destination('libdoc') && $opt{install_paths}->is_default_installable('libdoc') ) {
                my $section = $opt{config}->get('man3ext');
                for my $input ( keys %modules, keys %docs ) {
                    next unless contains_pod($input);
                    my $output = catfile( 'blib', 'libdoc', man3_pagename($input) );
                    manify( $input, $output, $section, \%opt );
                }
            }
            $self->_write_config_data( $install, $opt{meta}->name );
            return 0;
        },
        test => sub (%opt) {
            die "Must run `./Build build` first\n" if not -d 'blib';
            require TAP::Harness::Env;
            my %test_args = (
                ( verbosity => $opt{verbose} ) x !!exists $opt{verbose},
                ( jobs  => $opt{jobs} ) x !!exists $opt{jobs},
                ( color => 1 ) x !!-t STDOUT,
                lib => [ map { rel2abs( catdir( qw[blib], $_ ) ) } qw[arch lib] ],
            );
            my $tester = TAP::Harness::Env->create( \%test_args );
            local $ENV{PERL_DL_NONLAZY} = 1;
            return $tester->runtests( sort +find( qr/\.t$/, 't' ) )->has_errors;
        },
        install => sub (%opt) {
            die "Must run `./Build build` first\n" if not -d 'blib';
            install( $opt{install_paths}->install_map, @opt{qw[verbose dry_run uninst]} );
            return 0;
        },
        clean => sub (%opt) {
            rmtree( $_, $opt{verbose} ) for qw[blib temp];
            return 0;
        },
        realclean => sub (%opt) {
            rmtree( $_, $opt{verbose} ) for qw[blib temp Build _build_params MYMETA.yml MYMETA.json];
            return 0;
        },
    );
    my @options
        = qw[install_base=s install_path=s% installdirs=s destdir=s prefix=s config=s% uninst:1 verbose:1 dry_run:1 pureperl-only:1 create_packlist=i jobs=i extra_compiler_flags=s extra_linker_flags=s];

    sub get_arguments (@sources) {
        my %opt;
        GetOptionsFromArray( $_, \%opt, @options ) for @sources;
        $_                  = detildefy($_) for grep {defined} @opt{qw/install_base destdir prefix/}, values %{ $opt{install_path} };
        $_                  = [ split_like_shell($_) ] for grep {defined} @opt{qw/extra_compiler_flags extra_linker_flags/};
        $opt{config}        = ExtUtils::Config->new( $opt{config} );
        $opt{meta}          = get_meta();
        $opt{install_paths} = ExtUtils::InstallPaths->new( %opt, dist_name => $opt{meta}->name );
        return %opt;
    }

    method Build (@args) {
        my $action = @ARGV && $ARGV[0] =~ /\A\w+\z/ ? shift @ARGV : 'build';
        die "No such action '$action'\n" if not $actions{$action};
        my ( $env, $bargv ) = @{ decode_json( read_file('_build_params') ) };
        my %opt = get_arguments( $env, $bargv, \@ARGV );

        # 'build' is a method (needs $self for get_installer/_write_config_data);
        # the remaining actions are plain subs invoked MBT-style with only %opt.
        if ( $action eq 'build' ) {
            exit $actions{$action}->( $self, %opt );
        }
        exit $actions{$action}->(%opt);
    }

    sub Build_PL {
        my $meta = get_meta();
        printf "Creating new 'Build' script for '%s' version '%s'\n", $meta->name, $meta->version;
        my $dir = $meta->name eq 'Module-Build-Tiny' ? "use lib 'lib';" : '';
        my $use = __PACKAGE__;
        write_file( 'Build', "#!perl\nuse lib 'builder';\nuse $use;\n$use->new->Build();\n" );
        make_executable('Build');
        my @env = defined $ENV{PERL_MB_OPT} ? split_like_shell( $ENV{PERL_MB_OPT} ) : ();
        write_file( '_build_params', encode_json( [ \@env, \@ARGV ] ) );
        my %mymeta = %{ $meta->as_struct };

        if ( my $dynamic = $meta->custom('x_dynamic_prereqs') ) {
            my %opt = get_arguments( \@env, \@ARGV );
            require CPAN::Requirements::Dynamic;
            my $dynamic_parser = CPAN::Requirements::Dynamic->new(%opt);
            my $prereq         = $dynamic_parser->evaluate($dynamic);
            $mymeta{prereqs} = $meta->effective_prereqs->with_merged_prereqs($prereq)->as_string_hash;
        }
        $mymeta{dynamic_config} = 0;
        my $mymeta = CPAN::Meta->new( \%mymeta );
        $mymeta->save(@$_) for ['MYMETA.json'], [ 'MYMETA.yml' => { version => 1.4 } ];
    }

    method detect_platform () {

        # Detect host architecture from environment
        if ( ( $ENV{PROCESSOR_IDENTIFIER} || '' ) =~ m[ARM]i ||
            ( $ENV{PROCESSOR_ARCHITECTURE} || '' ) =~ /ARM64/i ||
            ( $ENV{PROCESSOR_ARCHITEW6432} || '' ) =~ /ARM64/i ) {
            $arch = 'arm64';
        }
        else {
            my $m = `uname -m 2>&1` || '';
            $arch = 'arm64' if $m =~ /aarch64|arm64/i;
        }
        $os = 'win'   if $os =~ /^MSWin32$/i;
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

    #~ use Data::Dump;
    method latest_release ( $tag //= () ) {

        #~ warn $tag;
        my $res = $self->http('latest');
        my $rel = decode_json( $res->{content} );

        #~ ddx $rel;
        return ( $rel, $rel->{tag_name} );    # XXX - if it's a prerelease version, grab full list and work continues...

        #~ return ( $rel, $rel->{tag_name} ) if $tag;
        #~ my ($current) = grep { $_->{prerelease} == JSON::PP::false and $_->{draft} == JSON::PP::false } @$rel;
        #~ die "no stable xmake release found\n" unless $current;
        #~ return ( $current, $current->{tag_name} );
    }

    method find_asset ( $assets, $re ) {
        for my $a (@$assets) { return $a if $a->{name} =~ /$re/ }
        return;
    }

    method get_installer (%opt) {
        my $share = rel2abs('share');
        mkpath($share) unless -d $share;
        my $config = $self->resolve_xmake( $share, %opt );
        say sprintf 'install_type: %s, version: %s, bin: %s', $config->{install_type}, $config->{version}, $config->{bin};
        return $config;
    }

    # Priority: 1) usable system xmake, 2) already-installed private copy in
    # share/, 3) prebuilt binary for the platform, 4) cosmocc portable bundle,
    # 5) build from source tarball.
    method resolve_xmake ( $share, %opt ) {
        unless ($force) {
            if ( my $sys = $self->find_system_xmake ) {
                my $ver = $self->xmake_version($sys);
                if ( $self->_version_ok( $ver, $version ) ) {
                    say "Found usable system Xmake: $sys ($ver)";
                    return { install_type => 'system', version => $ver, bin => "$sys" };
                }
                say "System Xmake ($ver) is older than the desired $version; installing a private copy.";
            }
            if ( my $cur = $self->current_share_install($share) ) {
                if ( $self->_version_ok( $cur->{version}, $version ) ) {
                    say "Reusing existing private Xmake ($cur->{version}) in $share";
                    return { install_type => $cur->{type}, version => $cur->{version}, bin => $cur->{bin} };
                }
                say "Existing private Xmake ($cur->{version}) is older than the desired $version; reinstalling.";
            }
        }
        return $self->install_fresh( $share, %opt );
    }

    # Locate an installed private copy in share/. Prefer the marker file we
    # wrote; fall back to classifying whatever layout is already present so
    # builds don't re-download when the folder was populated by older tooling.
    method current_share_install ($share) {
        my $marker = catfile( $share, '.alien-xmake.json' );
        if ( -e $marker ) {
            my $m = eval { decode_json( read_file($marker) ) };
            if ( $m && $m->{install_type} && $m->{version} && $m->{bin} ) {
                return { type => $m->{install_type}, version => $m->{version}, bin => $m->{bin} };
            }
        }
        return $self->classify_share($share);
    }

    method classify_share ($share) {
        my $exe = $^O eq 'MSWin32' ? 'xmake.exe' : 'xmake';
        for my $c ( [ 'source', [qw[bin]], $exe ], [ 'prebuilt', [qw[xmake]], $exe ], [ 'prebuilt', [], $exe ] ) {
            my ( $type, $sub, $name ) = @$c;
            my $path = @$sub ? catfile( $share, @$sub, $name ) : catfile( $share, $name );
            next unless -e $path;
            my $rel = @$sub ? join( '/', @$sub, $name ) : $name;
            return { type => $type, version => $self->xmake_version($path), bin => $rel };
        }
        return undef;
    }

    method install_fresh ( $share, %opt ) {
        my $assets = $rel->{assets};
        my $plan   = $self->choose_asset( $os, $arch, $version, $assets );
        die "no strategy matched platform ($os/$arch)\n" unless $plan;
        say "strategy: $plan->{strategy}";
        $asset = $self->find_asset( $assets, $plan->{pattern} ) or die "asset not found for pattern: $plan->{pattern}\n";
        if ($dryrun) {
            say "asset: $asset->{name} ($asset->{size} bytes)";
            say "would install into $share";
            exit 0;
        }

        # Replace whatever was there before so layouts can't mix.
        rmtree($share) if -d $share;
        mkpath($share);
        my $dest = $self->download_asset($asset);
        my ( $type, $bin_rel ) = $self->install_asset( $share, $dest, $plan, %opt );
        my $bin_path  = catfile( $share, grep {length} split m{/}, $bin_rel );
        my $installed = $self->xmake_version($bin_path);
        say "Installed Xmake $installed into $share ($type)";

        # Persist how this copy was installed so later builds can report it
        # without re-downloading.
        write_file( catfile( $share, '.alien-xmake.json' ), encode_json( { install_type => $type, version => $installed, bin => $bin_rel } ) );
        return { install_type => $type, version => $installed, bin => $bin_rel };
    }

    method install_asset ( $share, $dest, $plan, %opt ) {
        if ( $plan->{strategy} eq 'build' ) {
            my $bin = $self->build_from_source( $share, $dest, $opt{jobs} );
            return ( 'source', $bin );
        }
        my $exe = $^O eq 'MSWin32' ? 'xmake.exe' : 'xmake';
        if ( $dest =~ /\.zip$/i ) {
            $self->install_zip( $share, $dest );
            return ( 'prebuilt', $exe );
        }
        $self->install_bundle( $share, $dest, $exe );
        return ( $plan->{strategy} eq 'cosmocc' ? 'cosmocc' : 'prebuilt', $exe );
    }

    method download_asset ($asset) {
        my $dl = catdir( rel2abs('tmp'), 'xmake-downloads' );
        mkpath($dl) unless -d $dl;
        my $dest = catfile( $dl, $asset->{name} );
        say "downloading $asset->{name}";
        my $res = $http->mirror( $asset->{browser_download_url}, $dest );
        die "download failed: $res->{status} $res->{reason}\n" unless $res->{success};
        say "saved: $dest";
        return $dest;
    }

    # The win*.zip archive carries a top-level xmake/ folder; flatten it into
    # share/ so the layout matches the official installer (binary + data in one
    # directory) and File::ShareDir/runtime probing can find it.
    method install_zip ( $share, $zip ) {
        say 'Installing from prebuilt zip...';
        my $stage = catdir( rel2abs('tmp'), 'xmake-unzip-' . $$ );
        rmtree($stage) if -d $stage;
        mkpath($stage);
        $self->extract_zip( $zip, $stage );
        my $src = catdir( $stage, 'xmake' );
        $src = $stage unless -d $src;
        $self->copy_tree( $src, $share );
        rmtree($stage);
    }

    # cosmocc / macOS / linux x86_64 bundles are single self-contained
    # binaries. Install as share/xmake(.exe) with an xrepo wrapper alongside.
    method install_bundle ( $share, $bundle, $exe ) {
        say 'Installing portable bundle...';
        my $target = catfile( $share, $exe );
        copy( $bundle, $target ) or die "install_bundle: $!";
        chmod 0755, $target;
        my $wrap = catfile( $share, $^O eq 'MSWin32' ? 'xrepo.bat' : 'xrepo' );
        return if -e $wrap;
        my $content = $^O eq 'MSWin32' ? '@echo off' . "\n\"%~dp0$exe\" lua private.xrepo %*\n" :
            "#!/bin/sh\nsubdir=\"\$(CDPATH= cd -- \"\$(dirname -- \"\$0\")\" && pwd)\"\nexec \"\$subdir/$exe\" lua private.xrepo \"\$@\"\n";
        write_file( $wrap, $content );
        chmod 0755, $wrap;
    }

    # Last resort: replicate the official getter, ./configure && make && make
    # install, landing everything (binary + data) under $share/bin like the
    # upstream installer does.
    method build_from_source ( $share, $tgz, $jobs //= 4 ) {
        die "Building xmake from source on Windows requires MSYS2/mingw; use the prebuilt zip instead\n" if $^O eq 'MSWin32';
        my $make = _have_cmd('gmake') ? 'gmake' : _have_cmd('make') ? 'make' : die "xmake source build needs 'make' on PATH\n";
        die "xmake source build needs a C compiler (cc/gcc/clang) on PATH\n" unless _have_compiler();
        my $stage = catdir( rel2abs('tmp'), 'xmake-src-' . $$ );
        rmtree($stage) if -d $stage;
        mkpath($stage);
        say "Extracting $tgz...";
        $self->extract_targz( $tgz, $stage );
        opendir my $dh, $stage or die "can't read $stage: $!\n";
        my ($top) = grep { !/^\.\.?$/ && -d catdir( $stage, $_ ) } readdir $dh;
        closedir $dh;
        die "source archive did not unpack as expected\n" unless $top;
        my $src = catdir( $stage, $top );
        my $cwd = cwd();
        chdir $src or die "cannot chdir to $src: $!\n";

        if ( -f 'configure' ) {
            say 'Configuring...';
            system('./configure') == 0 or die "xmake configure failed\n";
        }
        say "Building with $make (jobs=$jobs)...";
        system( $make, "-j$jobs" ) == 0 or die "xmake make failed\n";
        say "Installing to $share...";
        system( $make, 'install', "PREFIX=$share" ) == 0 or die "xmake make install failed\n";
        chdir $cwd                                       or warn "cannot chdir back to $cwd: $!\n";
        rmtree($stage);
        my $exe = $^O eq 'MSWin32' ? 'xmake.exe' : 'xmake';
        my $bin = catfile( $share, 'bin', $exe );
        die "source build produced no xmake at $bin\n" unless -e $bin;
        my $wrap = catfile( $share, 'bin', $^O eq 'MSWin32' ? 'xrepo.bat' : 'xrepo' );

        if ( !-e $wrap ) {
            my $content = $^O eq 'MSWin32' ? '@echo off' . "\n\"%~dp0$exe\" lua private.xrepo %*\n" :
                "#!/bin/sh\nexec \"\$(dirname -- \"\$0\")\"/$exe lua private.xrepo \"\$@\"\n";
            write_file( $wrap, $content );
            chmod 0755, $wrap;
        }
        return 'bin/' . $exe;
    }

    # Decide what to fetch. Priority per answer:
    #   1. dedicated prebuilt for (os, arch)   -> download & (un)pack
    #   2. cosmocc portable bundle             -> download
    #   3. build from source tarball           -> download source
    method choose_asset( $os, $arch, $ver, $assets ) {
        my $has = sub { $self->find_asset( $assets, $_[0] ) };

        # Windows: use the .zip distribution, not the .exe (that's an NSIS
        # installer that prompts for elevation / UAC). The zip extracts a
        # self-contained local xmake.exe + xrepo with no system install.
        if ( $os eq 'win' ) {
            return { strategy => 'prebuilt', pattern => "xmake-v${ver}\\.win64\\.zip" } if $arch eq 'x86_64';
            return { strategy => 'prebuilt', pattern => "xmake-v${ver}\\.win32\\.zip" } if $arch eq 'x86';
            return { strategy => 'prebuilt', pattern => "xmake-v${ver}\\.arm64\\.zip" } if $arch eq 'arm64';

            # unknown windows cpu -> 64-bit fallback
            return { strategy => 'prebuilt', pattern => "xmake-v${ver}\\.win64\\.zip" };
        }
        if ( $os eq 'mac' ) {
            return { strategy => 'prebuilt', pattern => "xmake-bundle-v${ver}\\.macos\\.arm64" }  if $arch eq 'arm64';
            return { strategy => 'prebuilt', pattern => "xmake-bundle-v${ver}\\.macos\\.x86_64" } if $arch eq 'x86_64';
            return { strategy => 'prebuilt', pattern => "xmake-bundle-v${ver}\\.macos\\.x86_64" };
        }
        if ( $os eq 'linux' && $arch eq 'x86_64' ) {
            return { strategy => 'prebuilt', pattern => "xmake-bundle-v${ver}\\.linux\\.x86_64" } if $has->("xmake-bundle-v${ver}\\.linux\\.x86_64");
        }

        # The BSDs: the cosmocc universal bundle is unreliable here (OpenBSD
        # cannot exec it - "NUL byte unexpected"; FreeBSD fails its re-exec with
        # "Illegal seek" under redirected stdio). Build from source instead,
        # which is fully supported on FreeBSD/OpenBSD/NetBSD.
        if ( $os =~ /^(?:freebsd|openbsd|netbsd|dragonfly)$/ ) {
            return { strategy => 'build', pattern => "xmake-v${ver}\\.tar\\.gz" };
        }

        # every remaining platform (linux arm, etc.) -> cosmocc first,
        # build from source only if the cosmocc bundle is unavailable
        return { strategy => 'cosmocc', pattern => "xmake-bundle-v${ver}\\.cosmocc" } if $has->("xmake-bundle-v${ver}\\.cosmocc");
        return { strategy => 'build',   pattern => "xmake-v${ver}\\.tar\\.gz" };
    }
    method _version_ok ( $have, $want ) { $self->_version_cmp( $have, $want ) >= 0 }

    method _version_cmp ( $v1, $v2 ) {
        ( my $a = $v1 ) =~ s/^v//;
        ( my $b = $v2 ) =~ s/^v//;
        return version->parse($a) <=> version->parse($b);
    }

    method find_system_xmake () {
        my $sep  = $^O eq 'MSWin32' ? ';'                : ':';
        my @exts = $^O eq 'MSWin32' ? qw[.exe .cmd .bat] : ('');
        for my $dir ( split /$sep/, ( $ENV{PATH} // '' ) ) {
            next unless length $dir;
            for my $ext (@exts) {
                my $full = catfile( $dir, "xmake$ext" );
                return $full if -e $full && -f $full && -x _;
            }
        }
        return undef;
    }

    method xmake_version ($cmd) {
        my $safe = $^O eq 'MSWin32' ? qq{"$cmd"} : $cmd;
        my $out  = `$safe --version`;
        return "v$1" if $out =~ /xmake\s+v?(\d+\.\d+\.\d+)/i;
        return 'v0.0.0';
    }

    method extract_zip ( $zip, $out ) {
        my $uz = IO::Uncompress::Unzip->new($zip) or die "can't open zip $zip: $UnzipError\n";
        mkpath($out) unless -d $out;
        while ( my $status = $uz->nextStream() ) {
            my $name = $uz->getHeaderInfo()->{Name};
            next unless defined $name && length $name;

            # sanitise entry path: strip drive letters, leading slashes and
            # neutralise any ../ traversal so extraction stays inside $out
            $name =~ s{^[A-Za-z]:[/\\]+}{};
            $name =~ s{^[/\\]+}{};
            $name =~ s{(?:\.\./|\.\.\\)}{}g;
            next unless length $name;
            my $target = catfile( $out, grep {length} split m{[/\\]}, $name );
            if ( $name =~ m{[/\\]$} ) { mkpath($target); next; }
            my $parent = dirname($target);
            mkpath($parent) unless -d $parent;
            open my $fh, '>:raw', $target or die "can't write $target: $!\n";
            my $buf;

            while (1) {
                my $rc = $uz->read( $buf, 1_048_576 );
                die "Error reading from zip $zip: $UnzipError\n" if $rc < 0;
                last                                             if $rc == 0;
                print {$fh} $buf;
            }
            close $fh;
        }
    }

    method extract_targz ( $tgz, $out ) {
        mkpath($out) unless -d $out;

        # Prefer the system tar. IO::Uncompress::Gunzip chokes on the gzip
        # GitHub emits for these source tarballs (FNAME + multi-member), which
        # yields zero bytes even though tar/gzip decode it fine.
        if ( _have_cmd('tar') ) {
            my $dir = cwd();
            chdir $out or die "can't chdir to $out: $!\n";
            my $rc = system( 'tar', '-xzf', $tgz );
            chdir $dir or die "can't chdir back to $dir: $!\n";
            die "system tar failed to extract $tgz\n" unless $rc == 0;
            return;
        }

        my $raw;
        die "can't gunzip $tgz\n" unless IO::Uncompress::Gunzip::gunzip( $tgz => \$raw );
        my $at = Archive::Tar->new;
        open my $rfh, '<', \$raw or die "can't open tar stream: $!\n";
        die "can't read tar from $tgz\n" unless $at->read($rfh);
        for my $e ( $at->get_files ) {
            my $n = $e->full_path or next;
            next if $e->is_dir;
            my $target = catfile( $out, grep {length} split m{/}, $n );
            my $parent = dirname($target);
            mkpath($parent) unless -d $parent;
            open my $fh, '>:raw', $target or die "can't write $target: $!\n";
            print {$fh} $e->get_content;
            close $fh;
        }
    }

    method copy_tree ( $src, $dst ) {
        mkpath($dst) unless -d $dst;
        ( my $src_n = $src ) =~ tr{\\}{/};
        File::Find::find(
            sub {
                my $p = $File::Find::name;
                ( my $rel = $p ) =~ tr{\\}{/};

                # File::Find joins paths with '/'; normalise both sides so the
                # prefix strip survives on Windows.
                $rel =~ s{^\Q$src_n\E}{};
                $rel =~ s{^/+}{};
                my $target = length $rel ? catfile( $dst, grep {length} split m{/}, $rel ) : $dst;
                if ( -d $p ) { mkpath($target) unless -d $target; }
                else         { copy( $p, $target ) or die "copy $p -> $target: $!\n"; }
            },
            $src
        );
    }

    # Generate lib/Alien/Xmake/ConfigData.pm inside blib, recording how we got
    # xmake. install_type is one of: system, prebuilt, cosmocc, source.
    method _write_config_data ( $config, $dist_name ) {
        my $data = {%$config};
        if ( $data->{install_type} ne 'system' && $data->{bin} ) {

            # bin is stored relative to share/ (e.g. xmake.exe or bin/xmake);
            # rewrite it relative to this ConfigData so the installed module can
            # find the staged binary next to File::ShareDir's dist dir.
            my $base = rel2abs( catdir( 'blib', 'lib', 'Alien', 'Xmake' ) );
            my $root = rel2abs( catdir( 'blib', 'lib', 'auto',  'share', 'dist', $dist_name ) );
            my $abs  = rel2abs( catfile( $root, grep {length} split m{/}, $data->{bin} ) );
            $data->{bin} = abs2rel( $abs, $base );
        }
        my $dumper = Data::Dumper->new( [$data], ['conf'] );
        $dumper->Indent(1)->Terse(1)->Sortkeys(1);
        my $content = sprintf <<~'PERL', $dumper->Dump;
        package Alien::Xmake::ConfigData {
            use v5.40;
            use File::Spec;
            use File::Basename qw[dirname];

            my $config = %s;

            sub config ($s, $key //= ()) { defined $key ? $config->{$key} : $config }
            sub config_names { sort keys %%$config }

            #
            sub bin {
                my $bin = $config->{bin};
                return unless defined $bin;
                return $bin if $config->{install_type} eq 'system';
                File::Spec->rel2abs($bin, dirname(__FILE__))
            }
        };
        1;
        PERL
        my $dest   = catfile( rel2abs('blib'), 'lib', 'Alien', 'Xmake', 'ConfigData.pm' );
        my $parent = dirname($dest);
        mkpath($parent) unless -d $parent;
        write_file( $dest, $content );
        say "Generated $dest";
    }

    method http( $url //= '', %args ) {

        #~ warn $url =~ /https/ ? $url : qq[https://api.github.com/repos/$owner/$repo/releases/$url];
        my $res = $http->get( $url =~ /https/ ? $url : qq[https://api.github.com/repos/$owner/$repo/releases/$url], \%args );
        if ( $res->{status} == 403 && $res->{headers}{'x-ratelimit-remaining'} eq '0' ) {
            die 'github api rate limit exceeded: ' . _rate_message($res) . "\n";
        }

        #~ use Data::Dump;
        #~ ddx $res;
        die "github api failed: $res->{status} $res->{reason}\n" unless $res->{success} || $res->{status} == 304;
        $res;
    }

    sub _rate_message ($res) {
        my $limit     = $res->{headers}{'x-ratelimit-limit'};
        my $remaining = $res->{headers}{'x-ratelimit-remaining'};
        my $reset_utc = $res->{headers}{'x-ratelimit-reset'};
        my $msg       = 'github api rate limit';
        $msg .= " (limit=$limit"         if defined $limit;
        $msg .= ", remaining=$remaining" if defined $remaining;
        if ( defined $reset_utc && $reset_utc =~ /^\d+$/ ) {
            my $wait = $reset_utc - time();
            $wait = 0 if $wait < 0;
            my $mins = int( $wait / 60 );
            my $secs = $wait % 60;
            $msg .= sprintf( ", resets in ~%dm %02ds (%s)", $mins, $secs, scalar gmtime( $reset_utc + 0 ) );
        }
        return $msg . '; consider setting GITHUB_TOKEN to raise the limit';
    }

    sub _have_cmd ($name) {
        my $sep  = $^O eq 'MSWin32' ? ';'                : ':';
        my @exts = $^O eq 'MSWin32' ? qw[.exe .cmd .bat] : ('');
        for my $dir ( split /$sep/, ( $ENV{PATH} // '' ) ) {
            next unless length $dir;
            for my $ext (@exts) {
                my $full = catfile( $dir, "$name$ext" );
                return 1 if -e $full && -f $full && -x _;
            }
        }
        return 0;
    }

    sub _have_compiler () {
        for my $cc (qw[cc gcc clang]) { return 1 if _have_cmd($cc) }
        return 0;
    }
    };
1;
if ( $0 eq __FILE__ ) {
    chdir '../../../';
    Alien::Xmake::Builder->new->Build_PL;
    Alien::Xmake::Builder->new->Build;

    #~ Alien::Xmake::Builder->new->Build('test');
}
