package builder::xmake {
    use strict;
    use warnings;
    use parent 'Module::Build';
    use HTTP::Tiny            qw[];
    use File::Spec            qw[];
    use File::Basename        qw[];
    use Env                   qw[@PATH];              # Windows
    use File::Temp            qw[tempdir tempfile];
    use File::Spec::Functions qw[rel2abs];
    use File::Which           qw[which];
    use Archive::Tar          qw[];
    use Path::Tiny            qw[path];
    #
    my $version = '2.9.5';                            # Target install version
    my $installer_exe                                 # Pretend we're 64bit
        = "https://github.com/xmake-io/xmake/releases/download/v${version}/xmake-v${version}.win64.exe";
    my $installer_tar
        = "https://github.com/xmake-io/xmake/releases/download/v${version}/xmake-v${version}.tar.gz";
    my $share = rel2abs 'share';
    #
    sub http {
        CORE::state $http //= HTTP::Tiny->new(
            agent => 'Alien::xmake/' .
                shift->dist_version() . '; '    # space at the end asks HT to appended default UA
        );
        $http;
    }
    #
    sub locate_exe {
        my ( $s, $exe ) = @_;
        my $path = which($exe);
        $path ? rel2abs($path) : ();
    }
    sub install_with_exe { my ($s) = @_; }
    sub install_via_bash { my ($s) = @_; }

    #~ use File::ShareDir::Install;
    #~ warn File::ShareDir::Install::install_share( module => 'Alien::xmake');
    #~ warn File::Spec->rel2abs(
    #~ File::Basename::dirname(__FILE__), 'share'
    #~ );
    sub download {
        my ( $s, $url, $path ) = @_;
        my $local    = File::Spec->rel2abs( File::Spec->catfile( $s->cwd, $path ) );
        my $response = $s->http->mirror( $url, $local );
        if ( $response->{success} ) {
            $s->log_debug( 'Install executable mirrored at ' . $local );
            $s->make_executable($local);    # get it ready to run
            return $local;
        }
        $s->log_debug( 'Status: [' . $response->{status} . '] ' . $response->{content} );
        $s->log_warn( 'Failed to download ' . $response->{url} );
        return ();
    }

    #~ sub download_shget {
    #~ my ($s)      = @_;
    #~ my $local    = File::Spec->rel2abs( File::Spec->catfile( $s->cwd, 'xmake_installer.sh' ) );
    #~ my $response = $s->http->mirror( $installer_sh, $local );
    #~ if ( $response->{success} ) {
    #~ $s->log_debug( 'Install script mirrored at ' . $local );
    #~ $s->make_executable($local);    # get it ready to run
    #~ return $local;
    #~ }
    #~ $s->log_debug( 'Status: [' . $response->{status} . '] ' . $response->{content} );
    #~ $s->log_warn( 'Failed to download installer script from ' . $response->{url} );
    #~ exit 1;
    #~ }
    sub gather_info {
        my ( $s, $xmake, $xrepo ) = @_;
        warn $xmake;
        warn $xrepo;
        $s->config_data( xmake_exe => $xmake );
        $s->config_data( xrepo_exe => $xrepo );
        $s->config_data( xmake_dir => File::Basename::dirname($xmake) );
        my $run = `$xmake --version`;
        warn $run;
        my ($ver) = $run =~ m[xmake (v.+?), A cross-platform build utility based on Lua];
        $s->config_data( xmake_ver       => $ver );
        $s->config_data( xmake_installed => 1 );
    }

    # Module::Build subclass
    sub ACTION_xmake_install {
        my ($s) = @_;

        #~ return $s->config_data('xmake_type') if $s->config_data('xmake_type');
        #
        my $os = $s->os_type;    # based on Perl::OSType
        if ( !defined $os ) {
            $s->log_warn(
                q[Whoa. Perl has no idea what this OS is so... let's try installing with a shell script and hope for the best!]
            );
            exit 1;
        }
        elsif ( $os eq 'Windows' ) {
            $s->config_data( xmake_type => 'share' );
            $s->log_info(qq[Downloading $installer_exe...\n]);
            my $installer = $s->download( $installer_exe, 'xmake_installer.exe' );
            my $dest      = path( $s->base_dir )->child('share');
            $dest->mkdir;
            my $cmd = join ' ', $installer, '/NOADMIN', '/S', '/D=' . $dest->canonpath;
            $s->log_info(qq[Running $cmd\n]);
            $s->do_system($cmd);
            $s->log_info(qq[Installed to $dest\n]);
            push @PATH, $dest->realpath;
            path('.')->visit( sub { print "$_\n" }, { recurse => 1 } );
            system 'dir', $dest;

            #~ my $xmake = $s->locate_exe('xmake');
            #~ my $xrepo = $s->locate_exe('xrepo');
            $s->config_data( xmake_type => 'share' );

            #~ $s->gather_info( $xmake, $xrepo );
            #~ $s->config_data( xmake_install => $dest );
            return 'share'

# D:\a\_temp\1aa1c77c-ff7b-41bc-8899-98e4cd421618.exe /NOADMIN /S /D=C:\Users\RUNNER~1\AppData\Local\Temp\xmake-15e5f277191e8a088998d0f797dd1f44b5491e17
#~ $s->warn_info('Windows is on the todo list');
#~ exit 1;
        }
        else {
            #~ unshift @PATH, 'share/bin';
            my $xmake = $s->locate_exe('xmake');
            my $xrepo = $s->locate_exe('xrepo');
            if ($xmake) {
                $s->config_data( xmake_type => 'system' );
            }
            else {
                $s->build_from_source();
                unshift @PATH, 'share';
                #
                $s->config_data( xmake_type => 'share' );
                return 'share';
            }
            $xmake = $s->locate_exe('xmake');
            $xrepo = $s->locate_exe('xrepo');
            $s->gather_info( $xmake, $xrepo );

            #~ $s->config_data( xmake_install => $xmake );
            #~ return File::Spec->rel2abs($xmake);
            return;
        }
        return $s->config_data('xmake_type');
    }

    sub ACTION_code {
        my ($s) = @_;
        warn 'CODE';
        $s->depends_on('xmake_install');
        $s->SUPER::ACTION_code;
    }

    sub sudo {    # `id -u`;
        CORE::state $sudo;
        return $sudo if defined $sudo;
        $sudo = 'sudo' if !system 'sudo', '--version';
        $sudo //= '';
        return $sudo;
    }

    sub package_installer {
        CORE::state $pkg;
        return $pkg if defined $pkg;
        my %options = (
            apt        => 'apt --version',            # debian, etc.
            yum        => 'apt --version',
            zypper     => 'zypper --version',
            pacman     => 'pacman -V',                # arch, etc.
            emerge     => 'emerge -V',                # Gentoo
            pkg_termux => 'pkg list-installed',       # termux (Android)
            pkg_bsd    => 'pkg help',                 # freebsd
            nixos      => 'nix-env --version',
            apk        => 'apk --version',
            xbps       => 'xbps-install --version',
            scoop      => 'scoop --version',          # Windows
            winget     => 'winget --version',         # Windows
            brew       => 'brew --version',           # MacOS
            dnf        => 'dnf --help',               # Fedora, RHEL, OpenSUSE, CentOS
        );
        warn 'Looking for package manager...';
        no warnings 'exec';
        for my $plat ( keys %options ) {
            if ( system( $options{$plat} ) == 0 ) {
                $pkg = $plat;
                return $pkg;
            }
        }
    }

    sub build_from_source {
        my $s = shift;

        # get make
        my $make;
        {
            for (qw[make gmake]) {
                if ( `$_ --version` =~ /GNU Make/ ) {
                    $make = $_;
                    last;
                }
            }
            $make // warn 'Please install gmake';
        }
        my $compiler;
        {
            my ( $fh, $filename ) = tempfile();
            syswrite $fh, "#include <stdio.h>\nint main(){return 0;}";
            for (qw[gcc cc clang]) {
                if ( !system $_, qw'-x c', $filename,
                    qw'-o /dev/null -I/usr/include -I/usr/local/include' ) {
                    $compiler = $_;
                }
            }

            #~ $compiler // warn 'Please install a C compiler';
        }
        if ( !defined $make || !defined $compiler ) {
            my $sudo      = sudo();
            my $installer = package_installer();
            my %options   = (
                apt => "$sudo apt install -y git build-essential libreadline-dev ccache"
                ,    # debian, etc.
                yum =>
                    "yum install -y git readline-devel ccache bzip2 && $sudo yum groupinstall -y 'Development Tools'",
                zypper =>
                    "$sudo zypper --non-interactive install git readline-devel ccache && $sudo zypper --non-interactive install -t pattern devel_C_C++",
                pacman =>
                    "$sudo pacman -S --noconfirm --needed git base-devel ncurses readline ccache"
                ,                                                                 # arch, etc.
                emerge     => "$sudo emerge -atv dev-vcs/git ccache",             # Gentoo
                pkg_termux => "$sudo pkg install -y git getconf build-essential readline ccache"
                ,                                                                 # termux (Android)
                pkg_bsd => "$sudo pkg install -y git readline ccache ncurses",    # freebsd
                nixos   => "nix-env -i git gcc readline ncurses;",
                apk     =>
                    "$sudo apk add git gcc g++ make readline-dev ncurses-dev libc-dev linux-headers",
                xbps => "$sudo xbps-install -Sy git base-devel ccache",

                #scoop  => "$sudo ",                                               # Windows
                #winget => "$sudo ",                                               # Windows
                #brew   => 'brew --version',                                       # MacOS
                #dnf    => 'dnf --help',    # Fedora, RHEL, OpenSUSE, CentOS
            );
            $s->log_info( 'You should probably try running ' . $options{$installer} . "\n" )
                if defined $options{$installer};
            my $prebuilt = install_prebuilt();
            $s->log_info(
                'You could also install a prebuilt version of xmake with ' . $prebuilt . "\n" )
                if defined $prebuilt;
        }

        sub get_host_speed {
            my ($host) = @_;
            my $output = `ping -c 1 -W 1 $host 2>/dev/null`;
            $output =~ /time=([\d.]+)/ if $output;
            return $1 // 65535;
        }

        sub get_fast_host {
            my $gitee_speed  = get_host_speed("gitee.com");
            my $github_speed = get_host_speed("github.com");

            #~ CORE::say "gitee.com mirror took $gitee_speed ms";
            #~ CORE::say "github.com mirror took $github_speed ms";
            if ( $gitee_speed <= $github_speed ) {
                return 'gitee.com';
            }
            else {
                return 'github.com';
            }
        }
        my $cwd        = rel2abs('.');
        my $projectdir = tempdir( CLEANUP => 1 );
        my $workdir;
        my $archive = $s->download( $installer_tar, 'xmake.tar.gz' );
        if ( !$archive ) {
            $s->log_info('Failed to download source snapshot... Looking for git...');
            my $git;
            for (qw[git]) {
                if ( system( $_, '--version' ) == 0 ) {
                    $git = $_;
                    last;
                }
            }
            if ( !$git ) { $s->log_info('Cannot locate git. Giving up'); exit 1; }
            my $mirror = get_fast_host();
            $s->log_info("Using $mirror mirror...");
            my ( $gitrepo, $gitrepo_raw );
            if ( $mirror eq 'github.com' ) {
                $gitrepo = 'https://github.com/xmake-io/xmake.git';

                #$gitrepo_raw='https://github.com/xmake-io/xmake/raw/master';
                $gitrepo_raw = 'https://fastly.jsdelivr.net/gh/xmake-io/xmake@master';
            }
            else {
                $gitrepo     = "https://gitee.com/tboox/xmake.git";
                $gitrepo_raw = "https://gitee.com/tboox/xmake/raw/master";
            }
            #
            `git clone --depth=1 -b "v$version" "$gitrepo" --recurse-submodules $projectdir`
                unless -f $projectdir;
            chdir $projectdir;
            $workdir = $projectdir;
        }
        my $tar = Archive::Tar->new;
        $tar->read($archive);
        chdir $projectdir;
        $tar->extract();
        $workdir = $projectdir . '/xmake-' . $version;
        chdir $workdir;
        system './configure' unless -f 'makefile';
        system $make, '--jobs=5';
        system $make, 'install', qq[PREFIX=$share];
        chdir $cwd;    # I really should go to dist base dir
        return $share;
    }

    sub install_prebuilt {
        my $installer = package_installer();
        my $Win32 if $^O eq 'MSWin32';
        my $sudo    = sudo();
        my %options = (
            apt =>
                "$sudo add-apt-repository ppa:xmake-io/xmake && $sudo apt update && $sudo apt install xmake"
            ,                                                                   # debian, etc.
            pacman => ( $Win32 ? 'pacman -Sy mingw-w64-x86_64-xmake' : "$sudo pacman -Sy xmake" )
            ,                                                                   # arch, etc.
            emerge     => "$sudo emerge -a --autounmask dev-util/xmake",        # Gentoo
            pkg_termux => "$sudo pkg install -y xmake",                         # termux (Android)
            xbps       => "$sudo xbps-install -Sy git base-devel ccache",
            scoop      => "scoop install xmake",                                # Windows
            winget     => "winget install xmake",                               # Windows
            brew       => 'brew install xmake',                                 # MacOS
            dnf        =>
                "$sudo dnf copr enable waruqi/xmake && $sudo dnf install xmake" # Fedora, RHEL, OpenSUSE, CentOS
        );
        return $options{$installer} // ();
    }
}
1;
