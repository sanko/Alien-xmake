# Based on Module::Build::Tiny which is copyright (c) 2011 by Leon Timmermans, David Golden.
# Module::Build::Tiny is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Alien::Xmake::Builder {
    use CPAN::Meta;
    use ExtUtils::Install qw[pm_to_blib install];
    use ExtUtils::InstallPaths;
    use JSON::PP;
    use Config;
    use HTTP::Tiny;
    use Path::Tiny        qw[path cwd];
    use ExtUtils::Helpers qw[make_executable split_like_shell detildefy];
    use Data::Dumper;
    use IO::Uncompress::Unzip qw[$UnzipError];

    # Configuration
    field $target_version : param : reader //= 'v3.1.1';
    field $force  : param  //= 0;
    field $meta   : reader //= CPAN::Meta->load_file('META.json');
    field $action : param  //= 'build';
    field $target_config = 'lib/Alien/Xmake/ConfigData.pm';

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
    }

    method Build_PL() {
        die "Pure perl Affix? Ha! You wish.\n" if $pureperl;
        say sprintf 'Creating new Build script for %s %s', $meta->name, $meta->version;

        # We must capture the current INC to ensure the builder finds itself
        # when running the generated script.
        my $inc_str = join( ' ', map {"-I$_"} @INC );
        $self->write_file( 'Build', sprintf <<'', $^X, $inc_str, __PACKAGE__, __PACKAGE__ );
#!%s %s
use lib 'builder';
use %s;
%s->new( @ARGV && $ARGV[0] =~ /\A\w+\z/ ? ( action => shift @ARGV ) : (),
    map { /^--/ ? ( shift(@ARGV) =~ s[^--][]r => 1 ) : /^-/ ? ( shift(@ARGV) =~ s[^-][]r => shift @ARGV ) : () } @ARGV )->Build();

        make_executable('Build');
        my @env = defined $ENV{PERL_MB_OPT} ? split_like_shell( $ENV{PERL_MB_OPT} ) : ();
        $self->write_file( '_build_params', encode_json( [ \@env, \@ARGV ] ) );
        if ( my $dynamic = $meta->custom('x_dynamic_prereqs') ) {
            my %meta_struct = ( %{ $meta->as_struct }, dynamic_config => 1 );
            require CPAN::Requirements::Dynamic;
            my $dynamic_parser = CPAN::Requirements::Dynamic->new();
            my $prereq         = $dynamic_parser->evaluate($dynamic);
            $meta_struct{prereqs} = $meta->effective_prereqs->with_merged_prereqs($prereq)->as_string_hash;
            $meta = CPAN::Meta->new( \%meta_struct );
        }
        $meta->save(@$_) for ['MYMETA.json'];
    }

    # Actions
    method ACTION_build ( ) {
        say 'Building Alien-Xmake...';

        # Prepare blib
        path('blib/lib')->mkpath;
        path('blib/arch')->mkpath;
        path('blib/script')->mkpath;
        path('blib/bin')->mkpath;

        # Copy Libs
        $self->_copy_libs();

        # Alien Logic: Ensure Xmake is installed into the source share/ dir
        my $resolved = $self->_resolve_xmake();

        # Stage share/ into blib so File::ShareDir::dist_dir() can find it
        $self->_copy_share_to_blib();

        # Generate ConfigData.pm (used for upgrade detection on later builds)
        my $config_data
            = $resolved->{install_type} eq 'system' ? { install_type => 'system', version => $resolved->{version}, bin => $resolved->{bin} } :
            $self->_generate_share_config( $self->_staged_bin, $resolved->{version} );
        $self->_write_config_data($config_data);
        say 'Build complete';
    }

    method ACTION_install ( ) {
        say 'Installing...';
        require ExtUtils::Install;
        ExtUtils::Install::install( { 'blib/lib' => $Config{installprivlib}, 'blib/arch' => $Config{installarchlib} }, 1, 0, 0 );
    }

    method ACTION_clean () {
        say 'Cleaning...';
        path('blib')->remove_tree;
        path('_build_xmake')->remove_tree;
        path('config.log')->remove;
        path('Build')->remove;
        path('_build_params')->remove;
    }

    method ACTION_test ( ) {
        $self->ACTION_build();
        say 'Running tests...';
        use Test::Harness;
        my @tests = glob('t/*.t');
        runtests(@tests) if @tests;
    }

    method _copy_libs ( ) {
        my $src_root = path('lib');
        return unless $src_root->exists;
        my $iter = $src_root->iterator( { recurse => 1 } );
        while ( my $file = $iter->() ) {
            next unless $file->is_file;

            # Skip hidden files/dirs
            my $rel = $file->relative($src_root);
            next if $rel =~ m{(^|/)\.};
            my $dest = path('blib/lib')->child($rel);
            $dest->parent->mkpath;
            $file->copy($dest) or die "Copy failed: $!";
        }
    }

    method _copy_directory ( $src, $dest ) {
        my $src_path  = path($src)->absolute;
        my $dest_path = path($dest)->absolute;
        return unless $src_path->is_dir;
        $dest_path->mkpath;
        my $iter = $src_path->iterator( { recurse => 1 } );
        while ( my $p = $iter->() ) {
            next if $p eq $src_path;    # Skip root

            # Skip if we are inside the destination directory
            # (prevents infinite loop if dest is inside src)
            if ( $p eq $dest_path || $dest_path->subsumes($p) ) {
                next;
            }
            my $rel    = $p->relative($src_path);
            my $target = $dest_path->child($rel);
            if ( $p->is_dir ) {
                $target->mkpath;
            }
            else {
                $p->copy($target) or die "Failed to copy $p to $target: $!";
                $target->chmod( $p->stat->mode );
            }
        }
    }
    method _run_cmd (@args) { system(@args) == 0 }

    # Xmake lives in the source share/ dir, then gets staged into blib so
    # File::ShareDir::dist_dir() can locate it at run time.
    method _source_share ()   { path('share')->absolute; }
    method _dist_blib_root () { path( 'blib/lib/auto/share/dist', $meta->name )->absolute; }
    method _bin_name ()       { $^O eq 'MSWin32' ? 'xmake.exe' : 'xmake'; }
    method _staged_bin ()     { $self->_dist_blib_root->child( $self->_bin_name ); }

    method _copy_share_to_blib ( ) {
        my $src  = $self->_source_share;
        my $dest = $self->_dist_blib_root;
        return unless $src->is_dir;
        say "Staging share/ -> $dest";
        $self->_copy_directory( $src, $dest );
    }

    method _resolve_xmake ( ) {

        # Check for system install
        unless ($force) {
            my $sys_path = $self->_find_system_xmake();
            if ($sys_path) {
                my $ver = $self->_get_xmake_version($sys_path);
                if ( $self->_version_cmp( $ver, $target_version ) >= 0 ) {
                    say "Found suitable system Xmake: $sys_path ($ver)";
                    return { install_type => 'system', version => $ver, bin => "$sys_path" };
                }
                say "System Xmake found ($ver) but is older than required ($target_version).";
            }
        }

        # Check build dir (idempotency)
        my $install_dir = $self->_source_share;
        $install_dir->mkpath;
        my $bin_name = ( $^O eq 'MSWin32' ) ? 'xmake.exe' : 'xmake';
        my $blib_bin = $install_dir->child( 'bin', $bin_name );
        unless ( -x $blib_bin ) {
            my $fallback = $install_dir->child($bin_name);
            $blib_bin = $fallback if -x $fallback;
        }
        if ( -x $blib_bin ) {
            my $ver = $self->_get_xmake_version($blib_bin);
            if ( $self->_version_cmp( $ver, $target_version ) >= 0 ) {
                say "Alien-Xmake build up-to-date ($ver).";
                return { install_type => 'share', version => $ver };
            }
        }

        # Check existing shared installation for upgrading
        my $existing = $self->_check_existing_share();
        if ($existing) {
            my $ex_ver = $existing->{version};
            my $ex_dir = path( $existing->{install_dir} )->absolute;
            if ( $self->_version_cmp( $ex_ver, $target_version ) >= 0 ) {
                say "Found valid private Xmake ($ex_ver) in $ex_dir";
                if ( $ex_dir->stringify ne $install_dir->stringify ) {
                    say 'Copying existing installation to build directory...';
                    $self->_copy_directory( $ex_dir, $install_dir );
                }

                # Re-locate binary in new dir
                my $bin_path = $install_dir->child( 'bin', $bin_name );
                unless ( -x $bin_path ) { $bin_path = $install_dir->child($bin_name); }
                return { install_type => 'share', version => $ex_ver };
            }
        }

        # Download and Install
        say 'Installing a private copy of Xmake...';
        if ( $^O eq 'MSWin32' ) {
            $self->_install_windows($install_dir);
        }
        else {
            $self->_install_unix($install_dir);
        }

        # Verify Install
        my $bin_path = $install_dir->child( 'bin', $bin_name );
        unless ( -x $bin_path ) {
            my $fallback = $install_dir->child($bin_name);
            $bin_path = $fallback if -x $fallback;
        }
        if ( !-x $bin_path ) {
            die "Installation finished, but binary not found at $bin_path";
        }
        my $ver = $self->_get_xmake_version($bin_path);
        say "Private install successful: $ver";
        return { install_type => 'share', version => $ver };
    }

    method _generate_share_config( $bin_path, $version ) {

        # Calculate relative path from Alien/Xmake/ConfigData.pm to the
        # staged binary in the File::ShareDir location under blib.
        # ConfigData is in lib/Alien/Xmake/
        # Staged bin is in  blib/lib/auto/share/dist/Alien-Xmake/
        my $conf_base = path('blib/lib/Alien/Xmake')->absolute;
        my $rel_bin   = $bin_path->relative($conf_base)->stringify;
        return { install_type => 'share', version => $version, bin => $rel_bin };
    }

    method _check_existing_share() {
        eval { require Alien::Xmake::ConfigData; 1; } or return undef;
        my $type = eval { Alien::Xmake::ConfigData->config('install_type') } // '';
        return undef unless $type eq 'share';
        my $bin = eval { Alien::Xmake::ConfigData->bin };
        return undef unless $bin && -x $bin;
        my $ver      = $self->_get_xmake_version($bin);
        my $bin_path = path($bin);
        my $dir      = $bin_path->parent;

        if ( $dir->basename eq 'bin' ) {
            $dir = $dir->parent;
        }
        return { version => $ver, bin => $bin, install_dir => $dir };
    }

    method _find_system_xmake ( ) {
        my $sep = ( $^O eq 'MSWin32' ) ? ';' : ':';
        for my $dir ( split /$sep/, $ENV{PATH} ) {
            my $p    = path($dir);
            my $exts = ( $^O eq 'MSWin32' ) ? [qw(.exe .cmd .bat)] : [''];
            for my $ext (@$exts) {
                my $full = $p->child("xmake$ext");
                return $full if -x $full;
            }
        }
        return undef;
    }

    method _get_xmake_version ($cmd) {
        my $safe_cmd = ( $^O eq 'MSWin32' ) ? qq{"$cmd"} : "$cmd";
        my $out      = `$safe_cmd --version`;
        if ( $out =~ /xmake\s+v?(\d+\.\d+\.\d+)/i ) {
            return "v$1";
        }
        return 'v0.0.0';
    }

    method _version_cmp ( $v1, $v2 ) {
        require version;
        $v1 =~ s/^v//;
        $v2 =~ s/^v//;
        return version->parse($v1) <=> version->parse($v2);
    }

    method _write_config_data ($data) {
        my $dest = path('blib')->child($target_config);
        $dest->parent->mkpath;
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
        $dest->spew_utf8($content);
        say "Generated $dest";
    }

    method _install_windows ($installdir) {
        my $temppath = path('_build_xmake');
        $temppath->mkpath;
        my $arch     = $self->_native_windows_arch;
        my $filename;

        # Check for ARM64. The NSIS installer (xmake-$V.arm64.exe) supports the
        # /S /D silent-install flags just like win64/win32. The separate
        # "xmake-bundle-*.arm64.exe" assets are NOT NSIS installers; they are
        # xmake's own self-contained binaries that reject /S /D= and cannot be
        # used with the silent installer command below.
        if ( $arch eq 'ARM64' ) {
            $filename = "xmake-$target_version.arm64.exe";
        }

        # Check for x64 (AMD64/IA64)
        elsif ( $arch eq 'AMD64' || $arch eq 'IA64' ) {
            $filename = "xmake-$target_version.win64.exe";
        }

        # Fallback to x86
        else {
            $filename = "xmake-$target_version.win32.exe";
        }
        my $url     = "https://github.com/xmake-io/xmake/releases/download/$target_version/$filename";
        say "Detected Windows arch: $arch; installing $filename";
        my $outfile = $temppath->child('xmake-installer.exe');
        if ( !$self->_download_file( $url, $outfile ) ) {
            die "Download failed for $url";
        }
        my $install_str = $installdir->stringify;
        $install_str =~ s{/}{\\}g;
        my $outfile_str = $outfile->stringify;
        $outfile_str =~ s{/}{\\}g;
        say "Installing to $install_str...";

        # /NOADMIN: Avoid UAC prompt if possible (installs to local user path if allowed)
        # /S: Silent
        # /D: Destination directory
        my $cmd = qq{"$outfile_str" /NOADMIN /S /D=$install_str};
        my $ret = system($cmd);
        die "Installer failed with code $ret" if $ret != 0;

        # Cleanup
        #~ path('_build_xmake')->remove_tree;
    }

    # Detect the *host* CPU architecture on Windows, not the architecture of the
    # running perl. On Windows-on-ARM the Strawberry/x64 perl hardcodes its own
    # arch (x64) and PROCESSOR_* env vars mirror the *emulated process*, so all
    # of them report AMD64 even on ARM64 hardware. A C compiler built for the
    # host reports the true architecture via `-dumpmachine` (the same approach
    # infix's build.pl uses), so probe the available compilers first.
    method _native_windows_arch () {
        my $amd64;
        for my $cc ( 'clang', 'gcc', 'cc', 'cl' ) {
            my $m = $self->_probe_machine($cc);
            next unless defined $m;
            say "arch diagnostic: $cc -dumpmachine => $m";
            return 'ARM64' if $m =~ /aarch64|arm64/i;
            $amd64 ||= 1 if $m =~ /x86_64|amd64|i686|i386/i;
        }

        # Any native ARM64 compiler on the host trumps an emulated x64 toolchain
        # that happens to sit earlier on PATH (e.g. Strawberry's mingw gcc).
        return 'AMD64' if $amd64;
        say 'arch diagnostic: no compiler reported a usable target';

        # Fallback 1: GetNativeSystemInfo reports the native OS architecture.
        if ( eval { require Win32::API; 1 } ) {
            my $gns = Win32::API->new( 'kernel32', 'GetNativeSystemInfo', 'P', '' );
            if ($gns) {
                my $buf = "\0" x 48;
                $gns->Call($buf);
                my $w = unpack( 'v', substr( $buf, 0, 2 ) );
                say "arch diagnostic: GetNativeSystemInfo wProcessorArchitecture=$w";
                return 'ARM64' if $w == 12;
                return 'ARM'   if $w == 5;
                return 'AMD64' if $w == 9;
                return 'x86'   if $w == 0;
            }
            say 'arch diagnostic: Win32::API present but GetNativeSystemInfo unavailable';
        }
        else {
            say 'arch diagnostic: Win32::API not available; using env-var fallback';
        }

        # Fallback 2: the deprecated env-var heuristic.
        my $arch_env   = $ENV{PROCESSOR_ARCHITECTURE} // '';
        my $arch64_env = $ENV{PROCESSOR_ARCHITEW6432} // '';
        say "arch diagnostic: env PROCESSOR_ARCHITECTURE='$arch_env' PROCESSOR_ARCHITEW6432='$arch64_env'";
        return 'ARM64' if $arch_env eq 'ARM64' || $arch64_env eq 'ARM64';
        return 'AMD64' if $arch_env eq 'AMD64' || $arch_env eq 'IA64'
            || $arch64_env eq 'AMD64' || $arch64_env eq 'IA64';
        return 'x86';
    }

    # Run `<compiler> -dumpmachine` and return its target triple, or undef if
    # the compiler isn't found / produces no output.
    method _probe_machine ($cc) {
        my $null = _is_win() ? 'NUL' : '/dev/null';
        my $out  = `$cc -dumpmachine 2>$null`;
        return undef if ( $? >> 8 ) != 0;
        chomp $out if defined $out;
        return ( defined $out && length $out ) ? $out : undef;
    }


    method _install_unix ($installdir) {
        my $build_dir = path('_build_xmake');
        $build_dir->remove_tree;
        $build_dir->mkpath;
        my $sudo = '';
        if ( $> != 0 && $self->_run_cmd('sudo -n --version >/dev/null 2>&1') ) {
            $sudo = 'sudo';
        }
        unless ( $self->_test_tools() ) {

            # Do not auto-install system tools unless requested.
            if ( $ENV{ALIEN_INSTALL_SYSTEM_TOOLS} ) {
                say 'Attempting to install system tools via package manager...';
                if ( $self->_install_tools($sudo) ) {
                    $self->_test_tools() or $self->_raise_dep_error();
                }
                else {
                    $self->_raise_dep_error();
                }
            }
            else {
                $self->_raise_dep_error();
            }
        }
        my $version  = $target_version;
        my $filename = "xmake-$version.gz.run";
        my $gh_url   = "https://github.com/xmake-io/xmake/releases/download/$version/$filename";
        my $cdn_url  = "https://fastly.jsdelivr.net/gh/xmake-mirror/xmake-releases\@$version/$filename";
        my @urls;
        my $fasthost = $self->_get_fast_host();
        if ( $fasthost eq 'gitee.com' ) {
            @urls = ( $cdn_url, $gh_url );
        }
        else {
            @urls = ( $gh_url, $cdn_url );
        }
        my $outfile    = $build_dir->child('xmake.run');
        my $downloaded = 0;
        for my $url (@urls) {
            say "Attempting download from $url...";
            if ( $self->_download_file( $url, $outfile ) ) {
                $downloaded = 1;
                last;
            }
        }
        die 'All download attempts failed.' unless $downloaded;
        say 'Extracting source bundle...';
        $self->_run_cmd( 'sh', $outfile, '--noexec', '--quiet', '--target', $build_dir ) or die 'Failed to extract .run file';
        my $cwd = cwd();
        chdir $build_dir or die 'Cannot chdir to build dir';
        say 'Building Xmake...';

        # DETERMINE MAKE
        # On FreeBSD/NetBSD/OpenBSD/DragonFly, 'make' is BSD make.
        # Xmake generates GNU makefiles. We MUST use gmake.
        my $make_cmd = 'make';
        if ( $^O =~ /bsd/i || $^O eq 'dragonfly' ) {
            if ( $self->_run_cmd('gmake --version >/dev/null 2>&1') ) {
                $make_cmd = 'gmake';
            }
            else {
                # This should have been caught by _test_tools, but safe guard here
                die 'gmake is required on BSD systems to build Xmake.';
            }
        }
        elsif ( $self->_run_cmd('gmake --version >/dev/null 2>&1') ) {
            $make_cmd = 'gmake';
        }
        if ( -f 'configure' ) {
            say "Configuring with make=$make_cmd...";
            system( './configure', "--make=$make_cmd" ) == 0 or die 'Configure failed';
            system( $make_cmd,     '-j4' ) == 0              or die 'Make failed';
            say "Installing to $installdir...";
            system( $make_cmd, 'install', "PREFIX=$installdir" ) == 0 or die 'Install failed';
        }
        else {
            system( $make_cmd, 'build',   '-j4' ) == 0                or die 'Make build failed';
            system( $make_cmd, 'install', "prefix=$installdir" ) == 0 or die 'Make install failed';
        }
        chdir $cwd;
    }

    method _get_host_speed ($host) {
        my $cmd;
        if ( $^O eq 'darwin' ) {
            $cmd = "ping -c 1 -t 1 $host 2>/dev/null";
        }
        else {
            $cmd = "ping -c 1 -W 1 $host 2>/dev/null";
        }
        my $output = `$cmd`;
        if ( $output =~ /time=(\d+)/ ) {
            return $1;
        }
        return 65535;
    }

    method _get_fast_host ( ) {
        if ( $ENV{GITHUB_ACTIONS} ) {
            return 'github.com';
        }
        say 'Testing connection speed to github.com vs gitee.com...';
        my $speed_gitee  = $self->_get_host_speed('gitee.com');
        my $speed_github = $self->_get_host_speed('github.com');
        if ( $speed_gitee <= $speed_github ) {
            return 'gitee.com';
        }
        return 'github.com';
    }

    method _download_file ( $url, $dest ) {
        my $dest_str = "$dest";

        # Try HTTP::Tiny + IO::Socket::SSL
        if ( eval { require IO::Socket::SSL; 1 } ) {
            say 'Downloading with HTTP::Tiny...';
            my $http = HTTP::Tiny->new( verify_SSL => 1 );
            my $res  = $http->mirror( $url, $dest_str );
            if ( $res->{success} ) {
                return 1;
            }
            say "HTTP::Tiny failed: $res->{status} $res->{reason}";
        }
        else {
            say 'HTTP::Tiny skipped: IO::Socket::SSL not installed.';
        }

        # Try curl
        if ( $self->_run_cmd('curl --version >/dev/null 2>&1') ) {
            say 'Downloading with curl...';

            # -L: Follow redirects, -f: Fail on error, -o: Output
            if ( $self->_run_cmd( 'curl', '-L', '-f', '-o', $dest_str, $url ) ) {
                return 1;
            }
            say 'curl failed.';
        }

        # Try wget
        if ( $self->_run_cmd('wget --version >/dev/null 2>&1') ) {
            say 'Downloading with wget...';
            if ( $self->_run_cmd( 'wget', '--quiet', '-O', $dest_str, $url ) ) {
                return 1;
            }
            say 'wget failed.';
        }
        return 0;
    }

    method _test_tools ( ) {
        say 'Checking build tools...';
        my $ok = 1;

        # GNU or BSD make
        my $found_make = 0;
        if ( $self->_run_cmd('gmake --version >/dev/null 2>&1') ) {
            say ' - make: Found (gmake)';
            $found_make = 1;
        }
        elsif ( $self->_run_cmd('make --version >/dev/null 2>&1') ) {
            say ' - make: Found (make - likely GNU compatible)';
            $found_make = 1;
        }
        elsif ( $self->_run_cmd('make -V MACHINE >/dev/null 2>&1') ) {
            say ' - make: Found (make - BSD)';

            # If we are on BSD, this is technically 'found', but we know it won't work for Xmake.
            # We must fail here to trigger the installer if we are on BSD.
            if ( $^O =~ /bsd/i || $^O eq 'dragonfly' ) {
                say '   ! Note: BSD make is not compatible with Xmake build (needs gmake).';
            }
            else {
                $found_make = 1;    # On non-BSD systems, maybe they have a different make setup.
            }
        }

        # STRICT CHECK for BSDs
        if ( $^O =~ /bsd/i || $^O eq 'dragonfly' ) {
            unless ( $self->_run_cmd('gmake --version >/dev/null 2>&1') ) {
                say ' - make: Missing gmake (Required on FreeBSD/BSD for Xmake build)';
                $found_make = 0;
                $ok         = 0;
            }
            else {
                $found_make = 1;
            }
        }
        unless ($found_make) {
            say ' - make: Missing';
            $ok = 0;
        }

        # Compiler
        my $found_cc = 0;
        my $prog     = "#include <stdio.h>\nint main(){return 0;}";
        my @compilers
            = ( [ 'cc', '-xc', '-', '-o', '/dev/null' ], [ 'gcc', '-xc', '-', '-o', '/dev/null' ], [ 'clang', '-xc', '-', '-o', '/dev/null' ] );
        for my $cmd_ref (@compilers) {
            my $name    = $cmd_ref->[0];
            my $cmd_str = join( ' ', @$cmd_ref );
            my $pid     = open( my $ph, '|-', "$cmd_str >/dev/null 2>&1" );
            if ($pid) {
                print $ph $prog;
                close $ph;
                if ( $? == 0 ) {
                    say " - compiler: Found ($name)";
                    $found_cc = 1;
                    last;
                }
            }
        }
        unless ($found_cc) {
            say ' - compiler: Missing (checked cc, gcc, clang)';
            $ok = 0;
        }
        return $ok;
    }

    method _install_tools ($sudo) {
        my @installers = (
            [ 'apt --version', 'apt install -y git build-essential libreadline-dev' ],
            [ 'dnf --version', 'dnf install -y git readline-devel bzip2 @development-tools' ],
            [ 'yum --version', qq[yum install -y git readline-devel bzip2 && $sudo yum groupinstall -y 'Development Tools'] ],
            [   'zypper --version',
                qq[zypper --non-interactive install git readline-devel && $sudo zypper --non-interactive install -t pattern devel_C_C++]
            ],
            [ 'pacman -V',              'pacman -S --noconfirm --needed git base-devel ncurses readline' ],
            [ 'emerge -V',              'emerge -atv dev-vcs/git' ],
            [ 'pkg list-installed',     'pkg install -y git gmake' ],
            [ 'nix-env --version',      'nix-env -i git gcc readline ncurses' ],
            [ 'apk --version',          'apk add git gcc g++ make readline-dev ncurses-dev libc-dev linux-headers' ],
            [ 'xbps-install --version', 'xbps-install -Sy git base-devel' ]
        );
        for my $pair (@installers) {
            my ( $check, $install ) = @$pair;
            if ( $self->_run_cmd( $check . ' >/dev/null 2>&1' ) ) {
                say "Detected package manager via: $check";
                say 'Attempting to install dependencies...';
                return $self->_run_cmd( $sudo . ' ' . $install );
            }
        }
        return 0;
    }

    method _raise_dep_error () {
        die <<~'MSG';
    Dependencies Installation Failed or Skipped.

    We could not find the necessary tools (make, compiler) to build Xmake from source.

    You have three options:

    1. Install Xmake manually (Recommended if you lack build tools):
       See: https://xmake.io/guide/quick-start.html#installation
       Alien::Xmake will detect and use the system installation.

    2. Install build tools manually:
       * build-essential (make, gcc/clang, etc)
       * libreadline-dev / readline-devel

    3. Allow this builder to try installing system tools:
       Set ENV ALIEN_INSTALL_SYSTEM_TOOLS=1
    MSG
    }

    method write_file( $filename, $content ) {
        path($filename)->spew_raw($content);
    }

    method Build(@args) {
        my $method = $self->can( 'ACTION_' . $action );
        $method // die "No such action '$action'\n";
        exit !$method->($self);
    }

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

    sub _latest_release ($tag) {
        my $url = 'https://api.github.com/repos/xmake-io/xmake/releases';
        $url .= '/tags/' . $tag if $tag;
        my $res = _http->get($url);
        if ( $res->{status} == 403 && $res->{headers}{'x-ratelimit-remaining'} eq '0' ) {
            die 'github api rate limit exceeded: ' . _rate_message($res) . "\n";
        }
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
        return { strategy => 'bundle', pattern => "xmake-bundle-v${ver}.cosmocc" } if $has->("xmake-bundle-v${ver}.cosmocc");
        return { strategy => 'source', pattern => "xmake-v${ver}.tar.gz" };
    }

    sub _download ( $asset, $dest ) {
        return if -e $dest && -s $dest;
        my $res = _http->mirror( $asset->{browser_download_url}, $dest );
        die "download failed: $res->{status} $res->{reason}\n" unless $res->{success};
    }

    # The win*.zip archive contains a top-level xmake/ folder, so extracting
    # into $dist yields $dist/xmake/xmake.exe + $dist/xmake/xrepo.bat.
    sub _unzip ( $zip, $out ) {
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
    }

    # The cosmocc/mac/linux*.x86_64 bundles are single self contained binaries. Install as
    # $dist/xmake(.exe) and drop a sibling wrapper that exposes xrepo (`xmake lua private.xrepo`).
    sub _install_bundle ( $dist, $asset ) {
        my $exe     = File::Spec->catfile( $dist, _is_win() ? 'xmake.exe' : 'xmake' );
        my $wrapper = File::Spec->catfile( $dist, _is_win() ? 'xrepo.bat' : 'xrepo' );
        return if -e $exe && -s $exe && -e $wrapper;
        _download( $asset, $exe );
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
    sub _install_source ( $dist, $version, $rel ) {
        my $bin  = File::Spec->catfile( $dist, 'bin', _is_win() ? 'xmake.exe' : 'xmake' );
        my $wrap = File::Spec->catfile( $dist, 'bin', _is_win() ? 'xrepo.bat' : 'xrepo' );
        return if -e $bin && -e $wrap;
        die "xmake source build needs 'make' on PATH\n" unless _have_cmd('make');
        my $tmp = File::Spec->catdir( File::Spec->tmpdir, 'xmake-getter-' . $$ );
        remove_tree($tmp) if -d $tmp;
        mkpath($tmp);
        my $asset = _find_asset( $rel->{assets}, '\.tar\.gz$' );
        my $url   = $asset ? $asset->{browser_download_url} : $rel->{tarball_url};
        die "no source URL for xmake v$version\n" unless $url;
        my $name = ( $asset ? $asset->{name} : "xmake-v$version.tar.gz" );
        my $tgz  = File::Spec->catfile( $tmp, $name );
        _download( { browser_download_url => $url, name => $name }, $tgz );
        _untargz( $tgz, $tmp );
        opendir my $dh, $tmp or die "can't read $tmp: $!\n";
        my ($top) = grep { !/^\.\.?$/ && -d File::Spec->catdir( $tmp, $_ ) } readdir $dh;
        closedir $dh;
        my $src = $top ? File::Spec->catdir( $tmp, $top ) : undef;
        die "source archive did not unpack as expected\n" unless $src;
        my $cd = "cd '$src'";
        _run_or_die("$cd && ./configure") if -f File::Spec->catfile( $src, 'configure' );
        _run_or_die("$cd && make");
        my $qdist = $dist;
        $qdist =~ s/'/'\\''/g;
        _run_or_die("$cd && make install PREFIX='$qdist'");
        remove_tree($tmp);
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

    sub _untargz ( $tgz, $out ) {
        require IO::Uncompress::Gunzip;
        require Archive::Tar;
        my $raw;
        die "can't gunzip $tgz\n" unless IO::Uncompress::Gunzip::gunzip( $tgz => \$raw );
        my $at = Archive::Tar->new;
        open my $rfh, '<', \$raw or die "can't open tar stream: $!\n";
        die "can't read tar from $tgz\n" unless $at->read($rfh);
        mkpath($out)                     unless -d $out;

        for my $e ( $at->get_files ) {
            my $n = $e->full_path or next;
            next if $e->is_dir;
            my $target = File::Spec->catfile( $out, grep {length} split m{/}, $n );
            my $parent = dirname($target);
            mkpath($parent) unless -d $parent;
            open my $fh, '>:raw', $target or die "can't write $target: $!\n";
            print {$fh} $e->get_content;
            close $fh;
        }
    }

    sub _run_or_die ($cmd) {
        if ( ref $cmd eq 'ARRAY' ) {
            die "command failed\n" if system(@$cmd) != 0;
        }
        else {
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
        $xmake = File::Spec->catfile( $dist, 'xmake' . $ext )                               unless -e $xmake;
        $xrepo = File::Spec->catfile( $dist, 'xrepo' . ( _is_win() ? '.bat' : '' ) )        unless -e $xrepo;
        $xmake = File::Spec->catfile( $dist, 'bin', 'xmake' . $ext )                        unless -e $xmake;
        $xrepo = File::Spec->catfile( $dist, 'bin', 'xrepo' . ( _is_win() ? '.bat' : '' ) ) unless -e $xrepo;
        return ( $xmake, $xrepo );
    }

    sub _smoke_test ($dist) {
        my ( $xmake, $xrepo ) = _xmake_paths($dist);
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
        }
        return $ok;
    }

    sub _install_zip ( $dist, $asset ) {
        my $bin = File::Spec->catfile( $dist, 'xmake', 'xmake' . _is_win() ? '.exe' : 'xmake' );
        return if -e $bin && -s $bin;
        my $zip = File::Spec->catfile( $dist, $asset->{name} );
        _download( $asset, $zip );
        _unzip( $zip, $dist );
        unlink $zip if -e $zip;
    }

    sub _already_installed ($dist) {
        return 0 unless -d File::Spec->catdir( $dist, 'xmake' );
        my ( $xmake, $xrepo ) = _xmake_paths($dist);
        return -e $xmake && -s $xmake && -e $xrepo;
    }
};
1;
