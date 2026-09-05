use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Alien::Xrepo v0.9.4 {
    use Alien::Xmake;
    use JSON::PP;
    use Path::Tiny;
    use Config;
    use Capture::Tiny qw[capture];
    use Digest::MD5 ();
    use File::Spec;
    #
    field $verbose : param //= 0;
    field $root    : param //= undef;
    field $theme   : param //= 'plain';

    # Auto-confirm interactive xrepo/xmake prompts (e.g. -y / --confirm=yes). Useful when
    # output is captured (Capture::Tiny) so a prompting install never hangs waiting on stdin.
    field $yes     : param //= 0;
    field $confirm : param //= ();
    field $xmake = Alien::Xmake->new;

    # Resolve which package store a call should operate on. A per-call `installdir` wins, then the
    # `root` handed to the constructor, then whatever xrepo/the environment chooses (global store).
    method _store_dir (%opts) { return $opts{installdir} // $root }
    method blah       ($msg)  { return unless $verbose; say $msg; }
    #
    class    #
        Alien::Xrepo::PackageInfo v0.9.4 {
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
        field $installdir  : param : reader;
        field $kind        : param : reader //= ();

        # Helper to find a specific header inside the includedirs
        method find_header ($filename) {
            for my $dir (@$includedirs) {
                my $p = path($dir)->child($filename);
                return $p->stringify if $p->exists;
            }

            # Fallback check: sometimes xrepo returns the generic include root,
            # and the file is in a subdir (e.g. GL/gl.h)
            warn "Header '$filename' not found in package include directories:\n" . join( "\n", @$includedirs ) . "\n";
            return;
        }
        method bin_dir {@$bindirs}

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
                installdir  => $installdir,
                kind        => $kind
            }
        }
        }
        #
        method install ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};

        # Build common arguments for both install and fetch. The mutating install gets
        # an implicit -y unless the caller opted out; fetch is query-only, so no confirm.
        my @args = ( $self->_confirm_args(\%opts), $self->_build_args( \%opts ) );
        say "[*] xrepo: ensuring $full_spec is installed..." if $verbose;

        # Install (flags precede the package spec -- see _argv)
        my @install_cmd = $self->_argv( 'install', \@args, $full_spec );
        $self->blah("Running: @install_cmd");
        system(@install_cmd) == 0 or die "xrepo install failed for $full_spec";

        # Fetch (must use same args to get correct paths for arch/mode)
        warn "[*] xrepo: fetching paths...\n" if $verbose;
        my @fetch_args  = $self->_build_args( \%opts );
        my @fetch_cmd   = $self->_argv( 'fetch', [ '--json', @fetch_args ], $full_spec );
        $self->blah("Running: @fetch_cmd");
        my ( $json_out, $json_err, $json_exit ) = capture { system @fetch_cmd };
        die "xrepo fetch failed:\nCommand: @fetch_cmd\nError:\n$json_err" if $json_exit != 0;
        $self->blah("Raw fetch output:\n$json_out");
        my $data = $self->_decode_json_output($json_out);

        # xrepo might return a single object or a list.
        $self->_process_info( ( ref $data eq 'ARRAY' ) ? $data->[0] : $data );
    }

    method uninstall ( $pkg_spec, %opts ) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @args = ( $self->_confirm_args(\%opts), $self->_build_args( \%opts ) );
        push @args, '--all'   if $opts{all};
        push @args, '--force' if $opts{force};
        say "[*] xrepo: uninstalling $pkg_spec..." if $verbose;
        my @cmd = $self->_argv( 'remove', \@args, $pkg_spec );
        system @cmd;
    }

    method search ( $query, %opts ) {
        local $ENV{XMAKE_THEME} = $self->_theme(%opts);
        say "[*] xrepo: searching for $query..." if $verbose;
        my @flags = $opts{addon} ? ('--addon') : ();
        my @cmd   = $self->_argv( 'search', \@flags, $query );
        system @cmd;
    }

    method clean (%opts) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        say '[*] xrepo: cleaning cache...' if $verbose;
        my @cmd = $self->_argv( 'clean', ['-y'] );
        system @cmd;
    }
    #
    method add_repo ( $name, $url, $branch //= () ) {
        local $ENV{XMAKE_THEME} = $self->_theme;
        say "[*] xrepo: adding repo $name..." if $verbose;
        my @cmd = $self->_argv( 'add-repo', ['-y'], $name, $url, $branch );
        my ( $out, $err, $exit ) = capture { system @cmd };
        die "xrepo add-repo failed:\n$err" if $exit != 0;
        return 1;
    }

    method remove_repo ($name) {
        local $ENV{XMAKE_THEME} = $self->_theme;
        say "[*] xrepo: removing repo $name..." if $verbose;
        my @cmd = $self->_argv( 'remove-repo', ['-y'], $name );
        system @cmd;
    }

    method update_repo ( $name //= () ) {
        local $ENV{XMAKE_THEME} = $self->_theme;
        say '[*] xrepo: updating repositories...' if $verbose;
        my @cmd = $self->_argv( 'update-repo', ['-y'], $name );
        system @cmd;
    }
    #
    method _build_args ( $opts, $extra //= [] ) {
        my @args;

        # Auto-confirm interactive xrepo/xmake prompts so captured installs never hang.
        my $yes_c     = $opts->{yes}     // $yes;
        my $confirm_c = $opts->{confirm} // $confirm;
        push @args, '--confirm=' . $confirm_c if defined $confirm_c && length $confirm_c;
        push @args, '-y'                      if $yes_c             && !( defined $confirm_c && length $confirm_c );

        # Standard xmake/xrepo flags
        push @args, '-p', $opts->{plat} if $opts->{plat};                                  # platform (iphoneos, android, etc)
        push @args, '-a', $opts->{arch} if $opts->{arch};                                  # architecture (arm64, x86_64)
        push @args, '-m', $opts->{mode} if $opts->{mode};                                  # debug/release
        push @args, '-k', ( $opts->{kind} // 'shared' ) unless exists $opts->{no_kind};    # static/shared (Default to shared for FFI)
        push @args, '--toolchain=' . $opts->{toolchain}           if $opts->{toolchain};
        push @args, '--toolchain_host=' . $opts->{toolchain_host} if $opts->{toolchain_host};

        # Visual Studio
        push @args, '--vs=' . $opts->{vs}                 if $opts->{vs};
        push @args, '--vs_toolset=' . $opts->{vs_toolset} if $opts->{vs_toolset};
        push @args, '--vs_sdkver=' . $opts->{vs_sdkver}   if $opts->{vs_sdkver};

        # Android NDK
        push @args, '--ndk=' . $opts->{ndk} if $opts->{ndk};

        # Cross compilation
        push @args, '--sdk=' . $opts->{sdk}     if $opts->{sdk};
        push @args, '--mingw=' . $opts->{mingw} if $opts->{mingw};

        # Parallel builds / linking
        push @args, '-j', $opts->{jobs} if $opts->{jobs};
        push @args, '--linkjobs=' . $opts->{linkjobs} if $opts->{linkjobs};

        # Other configuration
        push @args, '--force'                         if $opts->{force};
        push @args, '--shallow'                       if $opts->{shallow};
        push @args, '--build'                         if $opts->{build};
        push @args, '--debugdir=' . $opts->{debugdir} if $opts->{debugdir};

        # Complex configs (passed as --configs='key=val,key2=val2')
        if ( my $c = $opts->{configs} ) {
            if ( ref $c eq 'HASH' ) {
                my $str = join( ',', map {"$_=$c->{$_}"} sort keys %$c );
                push @args, "--configs=$str";
            }
            else {
                push @args, "--configs=$c";
            }
        }

        # Build Includes. xrepo splits the `--includes` value on the OS path separator
        # (path.splitenv) and rejoins with path.joinenv into XMAKE_RCFILES, the contents of
        # which are textually PREPENDED to the temp project xmake.lua. True runtime-config
        # files (root-scope DSL like add_toolchains) are forwarded verbatim; but a *package
        # recipe* (package() {...}) is NOT valid in that project scope -- prepending it
        # corrupts the project script and xmake dies with e.g. "unknown interface:
        # add_rules()". Package files are therefore materialized into a temporary local
        # repository and an rc file that calls add_repositories() is emitted instead
        # (locally-registered repos are consulted before the bundled xmake-repo).
        my @rc;
        if ( my $i = $opts->{includes} ) {
            my @incs = ref $i eq 'ARRAY' ? @$i : split( /\Q$Config{path_sep}\E/, $i );
            my @recipes;
            for my $inc (@incs) {
                my $p = path($inc);
                if ( $p->is_file && $p->slurp_raw =~ /^\s*package\s*\(/m ) {
                    push @recipes, $p;
                }
                else {
                    push @rc, $p->absolute->stringify;
                }
            }
            push @rc, $self->_recipe_override_rc(\@recipes) if @recipes;
            push @args, '--includes=' . join( $Config{path_sep}, @rc ) if @rc;
        }

        # Extra per-action flags (e.g. --json, --cflags, --ldflags)
        push @args, @$extra;
        return @args;
    }

    # Theme used for xmake/xrepo output. Defaults to 'plain' (no ANSI); callers may pass
    # `theme =>` per-call, or `theme =>` to the constructor. xmake reads $ENV{XMAKE_THEME}.
    method _theme (%opts) { $opts{theme} // $theme }

    # Materialize vendored package recipe file(s) into a temporary local xmake repository
    # and return an rc file that registers it call add_repositories(). xmake consults
    # locally-registered repositories before the bundled xmake-repo, so the overridden
    # recipe wins for the package(s) it defines. The repo lives under the OS temp dir in a
    # subdir keyed by a hash of the concatenated recipe contents, so repeated install/fetch
    # calls are idempotent and stale overrides are never (re)registered for a different
    # recipe set.
    method _recipe_override_rc ($recipes) {
        return unless $recipes && @$recipes;
        my $ctx = join( "\x00", map { path($_)->slurp_raw } @$recipes );
        my $key = substr( Digest::MD5::md5_hex($ctx), 0, 12 );
        my $root = path( File::Spec->tmpdir, 'xrepo-local-repos', $key );

        for my $recipe (@$recipes) {
            $recipe = path($recipe);
            my @pkgs = $recipe->slurp_raw =~ /^\s*package\s*\(\s*["']([^"']+)["']/mg;
            @pkgs = ( $recipe->basename(qr/\.lua$/i) ) unless @pkgs;
            for my $pkg (@pkgs) {
                my $dest = $root->child( 'packages', substr( $pkg, 0, 1 ), $pkg, 'xmake.lua' );
                $dest->parent->mkpath;
                $recipe->copy($dest);
            }
        }

        my $repoxm = $root->child('xmake.lua');
        unless ( $repoxm->exists ) {
            $repoxm->spew("set_project(\"xrepo-local-repos\")\nadd_rules(\"mode.release\", \"mode.debug\")\n");
        }

        my $repopath = $root->absolute->stringify;
        $repopath =~ s{\\}{/}g;
        my $rc = $root->child('rc.lua');
        $rc->spew(qq{add_repositories("$key", "$repopath")\n}) unless $rc->exists;
        return $rc->absolute->stringify;
    }

    # Assemble a full xrepo CLI argv. The bundled xrepo 3.1.1 option parser treats an
    # option that follows the first positional package as another package name
    # (`xrepo install libsdl3_ttf --includes=X` leaks '--includes=X' into the package
    # list), so the package spec MUST be the trailing arguments. Every xrepo invocation
    # is routed through this helper to keep the flags-before-spec ordering invariant.
    method _argv ( $action, $flags, @spec ) {
        @spec = grep { defined } @spec;
        return ( $xmake->exe, qw[lua private.xrepo], $action, @$flags, @spec );
    }

    # Actions that mutate the package store auto-confirm (-y) unless the caller
    # explicitly opts out. The constructor's `yes =>` (or a per-call `yes =>` /
    # `confirm =>`) is honored by _build_args; this covers the "caller said nothing"
    # case so a captured install never hangs on an interactive prompt.
    method _confirm_args ($opts) {
        return ( '-y' ) if !$yes
            && !exists $opts->{yes}
            && !( defined $opts->{confirm} && length $opts->{confirm} );
        return ();
    }

    # Run `xrepo fetch` and return a parsed PackageInfo (or raw flags).
    method fetch ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;

        # Raw flag modes: return the string directly instead of a PackageInfo
        my $flags_mode = $opts{cflags} || $opts{ldflags};
        push @extra, '--cflags'  if $opts{cflags};
        push @extra, '--ldflags' if $opts{ldflags};
        push @extra, '--deps'    if $opts{deps};
        push @extra, '--system'  if $opts{system};
        push @extra, '-e'        if $opts{external};
        my @args      = ( '--json', $self->_build_args( \%opts, \@extra ) );
        my @fetch_cmd = $self->_argv( 'fetch', \@args, $full_spec );
        $self->blah("Running: @fetch_cmd");
        my ( $json_out, $json_err, $json_exit ) = capture { system @fetch_cmd };
        return if $json_exit != 0;

        # cflags/ldflags mode: xrepo returns a plain flag string, not JSON
        return $json_out if $flags_mode;
        $self->blah("Raw fetch output:\n$json_out");
        my $data = $self->_decode_json_output($json_out);

        # xrepo might return a single object or a list.
        return $self->_process_info( ( ref $data eq 'ARRAY' ) ? $data->[0] : $data );
    }

    method info ( $pkg_spec, %opts ) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;
        push @extra, '--depgraph'                if $opts{depgraph};
        push @extra, '--format=' . $opts{format} if $opts{format};
        my @args = $self->_build_args( \%opts, \@extra );
        say "[*] xrepo: showing info for $pkg_spec..." if $verbose;
        my @cmd = $self->_argv( 'info', \@args, $pkg_spec );
        my ( $out, $err, $exit ) = capture { system @cmd };
        return unless $exit == 0;

        # If the caller asked for machine-readable output, parse and return it
        if ( ( $opts{format} // '' ) eq 'json' && $out =~ /[\{\[]/ ) {
            my $data;
            try { $data = decode_json($out); } catch ($e) {
            }
            return $data if $data;
        }
        return $out;
    }

    method scan ( $pkg //= (), %opts ) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @args = $self->_build_args( { %opts, no_kind => 1 } );
        say '[*] xrepo: scanning installed packages...' if $verbose;
        my @cmd = $self->_argv( 'scan', \@args, ( defined $pkg && length $pkg ) ? $pkg : () );
        my ( $out, $err, $exit ) = capture { system @cmd };
        return () if $exit != 0;
        $self->blah($out);
        return split /\n/, $out;
    }

    method download ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;
        push @extra, '-o', $opts{outputdir} if $opts{outputdir};
        my @args = ( $self->_confirm_args(\%opts), $self->_build_args( \%opts, \@extra ) );
        say "[*] xrepo: downloading $full_spec..." if $verbose;
        my @cmd = $self->_argv( 'download', \@args, $full_spec );
        $self->blah("Running: @cmd");
        my ( $out, $err, $exit ) = capture { system @cmd };
        return 0 if $exit != 0;
        $self->blah($out);
        return 1;
    }

    method list_repo () {
        local $ENV{XMAKE_THEME} = $self->_theme;
        say '[*] xrepo: listing remote repositories...' if $verbose;
        my ( $out, $err, $exit ) = capture { system( $xmake->exe, qw[lua private.xrepo], 'list-repo' ) };
        return () if $exit != 0;
        $self->blah($out);
        return split /\n/, $out;
    }

    method import_pkg ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;
        push @extra, '-i', $opts{packagedir} if $opts{packagedir};
        my @args = ( $self->_confirm_args(\%opts), $self->_build_args( \%opts, \@extra ) );
        say "[*] xrepo: importing $full_spec..." if $verbose;
        my @cmd = $self->_argv( 'import', \@args, $full_spec );
        $self->blah("Running: @cmd");
        my ( $out, $err, $exit ) = capture { system @cmd };
        return 0 if $exit != 0;
        $self->blah($out);
        return 1;
    }

    method export ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;
        push @extra, '-o', $opts{packagedir} if $opts{packagedir};
        my @args = ( $self->_confirm_args(\%opts), $self->_build_args( \%opts, \@extra ) );
        say "[*] xrepo: exporting $full_spec..." if $verbose;
        my @cmd = $self->_argv( 'export', \@args, $full_spec );
        $self->blah("Running: @cmd");
        my ( $out, $err, $exit ) = capture { system @cmd };
        return 0 if $exit != 0;
        $self->blah($out);
        return 1;
    }

    method env ( $program //= (), %opts ) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @extra;
        push @extra, '--show' if $opts{show};
        push @extra, '--add',    $opts{add}    if $opts{add};
        push @extra, '--remove', $opts{remove} if $opts{remove};
        push @extra, '-l' if $opts{list};
        push @extra, '-b', $opts{bind} if $opts{bind};
        my @args = $self->_build_args( { %opts, no_kind => 1 }, \@extra );
        my @cmd  = $self->_argv( 'env', \@args, ( defined $program && length $program ) ? $program : (), @{ $opts{arguments} // [] } );
        say "[*] xrepo: running in package environment..." if $verbose;
        system @cmd;
    }

    # Decode xrepo `--json` output. xrepo can prefix the JSON with non-JSON "checking for X"
    # chatter (e.g. the MSVC/compiler check on first install on Windows), so we skip leading
    # prose lines and decode starting at the first JSON value line instead of demanding the
    # whole capture be pure JSON.
    method _decode_json_output ($raw) {
        die "xrepo produced no JSON: got empty output" unless defined $raw && length $raw;
        my ( $rest, $found );
        for my $line ( split /\r?\n/, $raw ) {
            if ( $line =~ /^\s*[\[{"]/ ) { $found = 1; }
            next unless $found;
            $rest .= $line . "\n";
        }
        die "xrepo produced no JSON; the probe/check chatter did not yield any JSON value.\nOutput was:\n$raw" unless $found;
        my $decoded = eval { decode_json($rest) };
        die "Failed to decode xrepo JSON output: $@\nOutput was:\n$raw" if !defined $decoded;
        return $decoded;
    }

    method _process_info ($info) {
        return () unless defined $info;
        my $libfiles   = $info->{libfiles}    // [];
        my $incdirs    = $info->{includedirs} // [];
        my $linkdirs   = $info->{linkdirs}    // [];
        my $bindirs    = $info->{bindirs}     // [];
        my $installdir = $info->{artifacts}{installdir};
        my $kind       = $info->{kind};
        if ( !defined $installdir ) {
            my ( $probe, $depth );
            if    (@$libfiles) { ( $probe, $depth ) = ( $libfiles->[0], 2 ); }
            elsif (@$incdirs)  { ( $probe, $depth ) = ( $incdirs->[0],  1 ); }
            if    ( defined $probe ) {
                my $p = path($probe);
                $p          = $p->parent for 1 .. $depth;
                $installdir = $p->stringify;
            }
        }
        unless (@$bindirs) {
            if ( $installdir && -d path( $installdir, 'bin' ) ) {
                $bindirs = [ path( $installdir, 'bin' )->stringify ];
            }
        }

        # A package that ships neither libraries nor headers but has an install root is a binary
        # tool (ninja, cmake, node, ...); anything else is a library (or header-only). xrepo only
        # reports `kind` for the former.
        if ( !defined $kind || !length $kind ) {
            $kind = ( defined $installdir && !@$libfiles && !@$incdirs ) ? 'binary' : 'library';
        }

        # Validate that we actually got files back
        unless (@$libfiles) {
            $self->blah('[!] xrepo returned no library files. Package might be header-only.');

            # Return a generic object (likely header-only)
            return Alien::Xrepo::PackageInfo->new(
                includedirs => $incdirs,
                libfiles    => [],
                libpath     => undef,
                linkdirs    => $linkdirs,
                links       => $info->{links}   // [],
                license     => $info->{license} // (),
                shared      => $info->{shared}  // 0,
                static      => $info->{static}  // 0,
                version     => $info->{version} // (),
                bindirs     => $bindirs,
                installdir  => $installdir,
                kind        => $kind
            );
        }

        # Heuristic to find the Runtime Library (DLL/SO/DyLib) for FFI
        my $runtime_lib;
        if ( $^O eq 'MSWin32' ) {

            # Check if the DLL is already in libfiles (MinGW often does this)
            ($runtime_lib) = grep {/\.dll$/i} @$libfiles;

            # If not, we must hunt for it in the 'bin' directory sibling to the 'lib' directory.
            unless ($runtime_lib) {
                my ($imp_lib) = grep {/\.lib$/i} @$libfiles;
                if ($imp_lib) {
                    my $lib_path = path($imp_lib);
                    my $basename = $lib_path->basename(qr/\.lib$/i);    # e.g., 'zlib' from 'zlib.lib'

                    # Construct list of potential directories to search
                    my @search_dirs = @$bindirs;

                    # Add standard relative paths: /path/to/lib/../bin
                    push @search_dirs, $lib_path->parent->parent->child('bin');
                    push @search_dirs, $lib_path->parent->sibling('bin');         # Some layouts differ

                    # Search for the DLL
                    for my $dir (@search_dirs) {
                        next unless -d $dir;
                        my $d = path($dir);

                        # Exact match: zlib.lib -> zlib.dll
                        my $try = $d->child("$basename.dll");
                        if ( $try->exists ) { $runtime_lib = $try->stringify; last; }

                        # MSVC vs MinGW naming: libpng.lib -> libpng16.dll or png.dll
                        # Scan directory for anything starting with the basename
                        my ($fuzzy) = grep { /^$basename/i && /\.dll$/i } map { $_->basename } $d->children;
                        if ($fuzzy) { $runtime_lib = $d->child($fuzzy)->stringify; last; }
                    }
                }
            }
        }
        elsif ( $^O eq 'darwin' ) {

            # macOS: Prefer .dylib, then .so
            ($runtime_lib) = grep {/\.dylib$/i} @$libfiles;
            ($runtime_lib) //= grep {/\.so$/i} @$libfiles;
        }
        else {
            # Linux/BSD: Prefer .so, .so.x.y, .so.x
            ($runtime_lib) = grep {/\.so(\.|-|\d|$)/} @$libfiles;
        }

        # Fallback and Logging
        unless ($runtime_lib) {

            # If we asked for shared but couldn't find a runtime binary, log a warning. We fall
            # back to the first file (likely a static .a/.lib) so that XS builds might still work,
            # even if Affix or FFI::Platypus will fail.
            if ( $info->{shared} // 0 ) {
                $self->blah('[!] Warning: Package is marked "shared" but no Runtime Binary (dll/so/dylib) was detected.');
                $self->blah( '[!] Libfiles returned: ' . join( ', ', @$libfiles ) );
            }
            $runtime_lib = $libfiles->[0];
        }
        $self->blah( '[*] Identified runtime library: ' . $runtime_lib ) if $runtime_lib;
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
            bindirs     => $bindirs,
            installdir  => $installdir,
            kind        => $kind
        );
    }
};
#
1;
__END__
Copyright (C) Sanko Robinson.

This library is free software; you can redistribute it and/or modify it under the terms found in
the Artistic License 2. Other copyrights, terms, and conditions may apply to data transmitted
through this module.
