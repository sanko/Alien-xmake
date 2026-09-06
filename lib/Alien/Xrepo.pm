use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Alien::Xrepo v0.9.5 {
    use Alien::Xmake;
    use JSON::PP;
    use Digest::SHA qw[sha1_hex];
    use File::Copy  qw[move];
    use Path::Tiny;
    use Config;
    use Capture::Tiny qw[capture capture_merged];
    use Cwd           ();
    #
    field $verbose : param //= 0;
    field $root    : param //= undef;
    field $theme   : param //= 'plain';

    # Auto-confirm interactive xrepo/xmake prompts (e.g. -y / --confirm=yes). Useful when
    # output is captured (Capture::Tiny) so a prompting install never hangs waiting on stdin.
    field $yes     : param //= 0;
    field $confirm : param //= ();
    field $xmake = Alien::Xmake->new;

    # Default package kind (-k) for every action; a per-call `kind` wins. Undef (the default)
    # omits -k so installs match a bare `xrepo` command, matching cd52e9b behavior.
    field $kind : param //= ();

    # Warm-start resolution cache. install() memorizes a successful fetch result under this
    # instance's store so a repeat launch skips xrepo entirely. Entries are LRU-bounded and a
    # hit is only trusted while its recorded install dir still exists. Pass cache => 0 to
    # disable (pure fetch-first behavior, one spawn per launch).
    field $cache : param //= 1;

    # Resolve which package store a call should operate on. A per-call `installdir` wins, then the
    # `root` handed to the constructor, then whatever xrepo/the environment chooses (global store).
    method _store_dir (%opts) { return $opts{installdir} // $root }
    method blah       ($msg)  { return unless $verbose; say $msg; }

    # Echo every command we are about to run
    method _debug_cmd (@cmd) {
        my $str = join( ' ', map { /\s/ ? qq{"$_"} : $_ } @cmd );
        my @env;
        push @env, "XMAKE_THEME=$ENV{XMAKE_THEME}"                   if defined $ENV{XMAKE_THEME};
        push @env, "XMAKE_PKG_INSTALLDIR=$ENV{XMAKE_PKG_INSTALLDIR}" if defined $ENV{XMAKE_PKG_INSTALLDIR};
        push @env, "XMAKE_PKG_CACHEDIR=$ENV{XMAKE_PKG_CACHEDIR}"     if defined $ENV{XMAKE_PKG_CACHEDIR};
        my $env = @env ? ' [ENV ' . join( ' ', @env ) . ']' : '';
        print "[XREPO] $str$env (cwd: @{[ Cwd::getcwd() ]})\n";
        return;
    }
    #
    class Alien::Xrepo::PackageInfo v0.9.5 {
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
    };
    #
    method install ( $pkg_spec, $version //= (), %opts ) {
        my $full_spec = defined $version && length $version ? "$pkg_spec $version" : $pkg_spec;
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};

        # Common arguments for install and fetch. The mutating install gets an implicit -y
        # unless the caller opted out; fetch is query-only, so no confirm.
        my @args = ( $self->_confirm_args( \%opts ), $self->_build_args( \%opts ) );
        say "[*] xrepo: ensuring $full_spec is installed..." if $verbose;

        # Warm path: a prior successful install+fetch is replayed straight from disk, so a
        # repeat launch (eg/webui.pl) skips xrepo entirely. The LRU is validated against the
        # recorded install dir before an entry is trusted.
        my $use_cache = defined $opts{cache} ? $opts{cache}                                                    : $cache;
        my $key       = $use_cache           ? $self->_cache_key( $full_spec, \%opts )                         : undef;
        my $meta      = $use_cache           ? ( $self->_cache_load(%opts) || { order => [], entries => {} } ) : undef;
        if ( $meta && defined $key ) {
            if ( my $hit = $self->_cache_get( $key, $meta ) ) {
                my $info = eval { $self->_process_info( decode_json( $hit->{json} ) ) };
                if ( ref $info ) {
                    $self->_cache_save( $meta, %opts );
                    return $info;
                }
            }
        }

        # Fetch-first: an already-installed package answers with real paths immediately, so the
        # mutating install is skipped (and the result is memorized for next launch).
        my ( $data, $err ) = $self->_try_fetch( $full_spec, \%opts );
        if ( defined $data && $self->_info_installed($data) ) {
            say "[*] xrepo: $full_spec already installed, reusing fetch result..." if $verbose;
            if ( $meta && defined $key ) {
                $self->_cache_put( $key, $meta, $self->_cache_entry($data) );
                $self->_cache_save( $meta, %opts );
            }
            return $self->_process_info($data);
        }

        # Cold path: install, then fetch (which must succeed, since it tells us where things land).
        my @install_cmd = $self->_argv( 'install', \@args, $full_spec );
        $self->_debug_cmd(@install_cmd);
        $self->blah("Running: @install_cmd");
        system(@install_cmd) == 0 or die "xrepo install failed for $full_spec";
        say "[*] xrepo: fetching paths..." if $verbose;
        my $fresh = $self->_require_fetch( $full_spec, \%opts, $err );
        if ( $meta && defined $key ) {
            $self->_cache_put( $key, $meta, $self->_cache_entry($fresh) );
            $self->_cache_save( $meta, %opts );
        }
        $self->_process_info($fresh);
    }

    # --- install-result cache -------------------------------------------------
    # LRU cap on cached resolutions. Entries are just the fetch JSON plus its install dir, so
    # the bound keeps the file a few hundred KB even after a long debugging session.
    sub _CACHE_MAX () {64}

    # Where the resolution cache lives: alongside the caller's/instance's store when one is set,
    # else the xmake global dir (~/.xmake) that xrepo itself uses for the default per-user store.
    method _cache_dir (%opts) {
        my $store = $self->_store_dir(%opts);
        return path($store)->child('.alien-xmake') if defined $store && length $store;
        my $home = $ENV{XMAKE_GLOBALDIR};
        $home //= $ENV{HOME};
        if ( !defined $home || !length $home ) {
            $home = $^O eq 'MSWin32' ? "$ENV{HOMEDRIVE}$ENV{HOMEPATH}" : ();
        }
        return () if !defined $home || !length $home;
        path($home)->child( '.xmake', '.alien-xmake' );
    }

    # Cache identity: everything that can move the installed layout. configs values run through
    # the same boolean stringifier as the CLI, so built-in true/false produce a stable key.
    method _cache_key ( $full_spec, $opts ) {
        my @parts = ( $full_spec, $opts->{kind} // '', $opts->{plat} // '', $opts->{arch} // '', $opts->{mode} // '' );
        if ( my $c = $opts->{configs} ) {
            my $str = ref $c eq 'HASH' ? join( ',', map { "$_=" . Alien::Xmake::_bool_str( $c->{$_} ) } sort keys %$c ) : "$c";
            push @parts, $str;
        }
        sha1_hex( join( "\0", @parts ) );
    }

    method _cache_load (%opts) {
        my $dir  = $self->_cache_dir(%opts) or return ();
        my $file = $dir->child('cache.json');
        return () unless -f $file;
        my $raw = eval { $file->slurp_utf8 };
        return () unless defined $raw && length $raw;
        my $meta = eval { decode_json($raw) };
        return () unless ref $meta eq 'HASH' && ref $meta->{order} eq 'ARRAY' && ref $meta->{entries} eq 'HASH';
        $meta;
    }

    method _cache_save ( $meta, %opts ) {
        my $dir = $self->_cache_dir(%opts) or return;
        my ( @order, %keep );
        for my $k ( @{ $meta->{order} // [] } ) {
            my $e = $meta->{entries}{$k} or next;
            next unless $self->_entry_alive($e);
            push @order, $k;
            $keep{$k} = $e;
        }
        while ( @order > _CACHE_MAX() ) { delete $keep{ pop @order }; }
        $dir->mkpath;
        my $file = $dir->child('cache.json');
        my $tmp  = $dir->child('cache.json.tmp');
        $tmp->spew_utf8( encode_json( { version => 1, order => \@order, entries => \%keep } ) );
        move( "$tmp", "$file" );
    }

    # A cached entry is trustworthy only while its recorded install dir (or first lib) still
    # exists; uninstalled packages disqualify themselves and are pruned on the next save.
    method _entry_alive ($e) {
        return () unless ref $e eq 'HASH';
        if ( defined $e->{installdir} && length $e->{installdir} ) { return 1 if -d $e->{installdir}; }
        if ( defined $e->{libpath}    && length $e->{libpath} )    { return 1 if -f $e->{libpath}; }
        ();
    }

    method _cache_get ( $key, $meta ) {
        my $e = $meta->{entries}{$key} or return ();
        return () unless $self->_entry_alive($e);
        $e->{last_used} = time;
        $meta->{order}  = [ $key, grep { $_ ne $key } @{ $meta->{order} } ];
        $e;
    }

    method _cache_put ( $key, $meta, $entry, $max //= _CACHE_MAX() ) {
        $meta->{entries}{$key} = $entry;
        $meta->{order} = [ $key, grep { $_ ne $key } @{ $meta->{order} } ];
        while ( @{ $meta->{order} } > $max ) {
            delete $meta->{entries}{ pop @{ $meta->{order} } };
        }
        $meta;
    }

    method _cache_entry ($data) {
        my $info  = ref $data eq 'ARRAY' ? $data->[0] : $data;
        my %entry = ( json => encode_json($data), last_used => time );
        if ( ref $info eq 'HASH' ) {
            my $art = $info->{artifacts};
            if    ( ref $art eq 'HASH' && defined $art->{installdir} ) { $entry{installdir} = $art->{installdir}; }
            elsif ( defined $info->{installdir} )                      { $entry{installdir} = $info->{installdir}; }
            if    ( @{ $info->{libfiles} // [] } )                     { $entry{libpath}    = $info->{libfiles}[0]; }
        }
        \%entry;
    }

    # Query-only fetch that reports failure instead of dying, so install() can first probe
    # whether a package is already installed. Returns ( $data, $errmsg ); $data is undef on any
    # failure (bad exit, no JSON, undecodable chatter) and the message is passed to the caller.
    method _try_fetch ( $full_spec, $opts ) {
        my @fetch_args = $self->_build_args($opts);
        my @fetch_cmd  = $self->_argv( 'fetch', [ '--json', @fetch_args ], $full_spec );
        $self->_debug_cmd(@fetch_cmd);
        $self->blah("Running: @fetch_cmd");
        my ( $out, $err, $exit ) = capture { system @fetch_cmd };
        return ( undef, "Command: @fetch_cmd\nError:\n$err" ) if $exit != 0;
        return ( undef, "Command: @fetch_cmd\nNo JSON output" ) unless defined $out && length $out;
        my $data = eval { $self->_decode_json_output($out) };
        return ( undef, "Command: @fetch_cmd\n$@" ) if !defined $data;
        ( $data, undef );
    }

    # Mandatory fetch: after an install we have to know where the output landed, so a failure
    # here is fatal. $why carries the earlier probe error so the die explains which attempt failed.
    method _require_fetch ( $full_spec, $opts, $why //= () ) {
        my ( $data, $err ) = $self->_try_fetch( $full_spec, $opts );
        unless ( defined $data ) {
            die "xrepo fetch failed:\n$err\n" . ( defined $why && length $why ? "\n(an earlier fetch probe also failed:\n$why)" : () );
        }
        $data;
    }

    # Verify a fetched record corresponds to files that actually exist on disk; xrepo fetch of a
    # not-yet-installed package can still exit 0 with an empty/speculative record.
    method _info_installed ($data) {
        my $info = ref $data eq 'ARRAY' ? $data->[0] : $data;
        return () unless ref $info eq 'HASH';
        my $art        = $info->{artifacts};
        my $installdir = ref $art eq 'HASH' && defined $art->{installdir} ? $art->{installdir} : $info->{installdir};
        return 1 if defined $installdir && -d $installdir;
        for my $f ( @{ $info->{libfiles} // [] } ) { return 1 if -f $f; }
        for my $d ( @{ $info->{bindirs}  // [] } ) { return 1 if -d $d; }
        ();
    }

    method uninstall ( $pkg_spec, %opts ) {
        local $ENV{XMAKE_THEME}          = $self->_theme(%opts);
        local $ENV{XMAKE_PKG_INSTALLDIR} = $self->_store_dir(%opts) if defined $self->_store_dir(%opts);
        local $ENV{XMAKE_PKG_CACHEDIR}   = $opts{cachedir}          if defined $opts{cachedir};
        my @args = ( $self->_confirm_args( \%opts ), $self->_build_args( \%opts ) );
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
        push @args, '-p', $opts->{plat} if $opts->{plat};                    # platform (iphoneos, android, etc)
        push @args, '-a', $opts->{arch} if $opts->{arch};                    # architecture (arm64, x86_64)
        push @args, '-m', $opts->{mode} if $opts->{mode};                    # debug/release
        my $kind = defined $opts->{kind} && length $opts->{kind} ? $opts->{kind} : $kind;
        push @args, '-k', $kind
            if !exists $opts->{no_kind} && defined $kind && length $kind;    # emit `-k` only when a consumer asks for a specific kind
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
                my $str = join( ',', map { "$_=" . Alien::Xmake::_bool_str( $c->{$_} ) } sort keys %$c );
                push @args, "--configs=$str";
            }
            else {
                push @args, "--configs=$c";
            }
        }

        # Build Includes. xrepo splits the `--includes` value on the OS path separator
        # and rejoins with path.joinenv into XMAKE_RCFILES, the contents of which
        # are textually PREPENDED to the temp project xmake.lua. Only genuine
        # root-scope rc content (add_toolchains, etc.) belongs here: a vendored
        # *package recipe* (package() {...}) is invalid in that scope and dies
        # with e.g. "unknown interface: add_rules()", so recipe overrides are
        # not supported.
        my @rc;
        if ( my $i = $opts->{includes} ) {
            my @incs = ref $i eq 'ARRAY' ? @$i : split( /\Q$Config{path_sep}\E/, $i );
            push @rc,   map { path($_)->absolute->stringify } @incs;
            push @args, '--includes=' . join( $Config{path_sep}, @rc ) if @rc;
        }

        # Extra per-action flags (e.g. --json, --cflags, --ldflags)
        push @args, @$extra;
        return @args;
    }

    # Theme used for xmake/xrepo output. Defaults to 'plain' (no ANSI); callers may pass
    # `theme =>` per-call, or `theme =>` to the constructor. xmake reads $ENV{XMAKE_THEME}.
    method _theme (%opts) { $opts{theme} // $theme }

    # Assemble a full xrepo CLI argv. The bundled xrepo 3.1.1 option parser treats an
    # option that follows the first positional package as another package name
    # (`xrepo install libsdl3_ttf --includes=X` leaks '--includes=X' into the package
    # list), so the package spec MUST be the trailing arguments. Every xrepo invocation
    # is routed through this helper to keep the flags-before-spec ordering invariant.
    # xrepo keeps a scratch project at os.tmpdir()/xrepo/working and runs `xmake
    # create -P .` there the first time it is missing. On MSWin32 under GitHub
    # Actions that create child aborts while rewriting the scaffold, so the workdir
    # is left with a raw template (unexpanded ${TARGET_NAME}/${FAQ}) and every later
    # xrepo action dies parsing it (`.\xmake.lua: unexpected symbol near '$'`).
    # Pre-sow the directory with a valid project (xrepo only checks os.isdir) and
    # repair any poisoned xmake.lua left behind by a failed create.
    method _ensure_working_project () {
        return unless $^O eq 'MSWin32';
        my $tmp = $ENV{TEMP};
        return unless defined $tmp && length $tmp && -d $tmp;
        my ( undef, undef, undef, $mday, $mon, $year ) = localtime;
        my $work = path($tmp)->child( '.xmake', sprintf( '%02d%02d%02d', $year % 100, $mon + 1, $mday ), 'xrepo', 'working' );
        $work->mkpath;
        my $xmake_lua = $work->child('xmake.lua');
        if ( !$xmake_lua->exists || $xmake_lua->slurp =~ /\$\{/ ) {

            # A failed create leaves a read-only raw template here; Path::Tiny's
            # spew renames over it and dies Permission denied, so unlink first.
            $xmake_lua->remove if $xmake_lua->exists;
            $xmake_lua->spew( "add_rules(\"mode.debug\", \"mode.release\")\n\n" .
                    "target(\"working\")\n" .
                    "    set_kind(\"binary\")\n" .
                    "    add_files(\"src/*.cpp\")\n\n" );
        }
        my $main = $work->child( 'src', 'main.cpp' );
        $work->child('src')->mkpath               unless $main->parent->is_dir;
        $main->spew("int main() { return 0; }\n") unless $main->exists;
        return;
    }

    method _argv ( $action, $flags, @spec ) {
        $self->_ensure_working_project;
        @spec = grep {defined} @spec;
        return ( $xmake->exe, qw[lua private.xrepo], $action, @$flags, @spec );
    }

    # Actions that mutate the package store auto-confirm (-y) unless the caller
    # explicitly opts out. The constructor's `yes =>` (or a per-call `yes =>` /
    # `confirm =>`) is honored by _build_args; this covers the "caller said nothing"
    # case so a captured install never hangs on an interactive prompt.
    method _confirm_args ($opts) {
        return ('-y') if !$yes && !exists $opts->{yes} && !( defined $opts->{confirm} && length $opts->{confirm} );
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
        my @args = ( $self->_confirm_args( \%opts ), $self->_build_args( \%opts, \@extra ) );
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
        my @args = ( $self->_confirm_args( \%opts ), $self->_build_args( \%opts, \@extra ) );
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
        my @args = ( $self->_confirm_args( \%opts ), $self->_build_args( \%opts, \@extra ) );
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
        $info = $info->[0] if ref $info eq 'ARRAY';
        return () unless ref $info eq 'HASH';
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
