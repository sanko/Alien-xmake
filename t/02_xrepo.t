use v5.40;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Alien::Xmake;
use Alien::Xrepo;
#
ok $Alien::Xrepo::VERSION, 'Alien::Xrepo::VERSION';
#
my $repo  = Alien::Xrepo->new( verbose => 0 );
my $xmake = Alien::Xmake->new;
my $exe   = $xmake->exe;
subtest 'repository mirror pinning' => sub {
    my $bin_url  = 'https://github.com/xmake-mirror/build-artifacts.git';
    my $main_url = 'https://github.com/xmake-io/xmake-repo.git';
    Alien::Xrepo->new( binary_repo => $bin_url, main_repo => $main_url );
    is $ENV{XMAKE_BINARY_REPO}, $bin_url,  'XMAKE_BINARY_REPO is set to binary_repo';
    is $ENV{XMAKE_MAIN_REPO},   $main_url, 'XMAKE_MAIN_REPO is set to main_repo';
};

#~ diag `$exe --help`;
#~ diag $exe;
#~ diag `$exe update`;
#~ xmake.exe lua private.xrepo install -y -k shared zlib
#~ diag `$exe lua private.xrepo install -y -k shared zlib`;
$repo->update_repo;
ok my $pkg = $repo->install('zlib'), 'install zlib';
skip_all 'Failed to install zlib', 3 unless $pkg;
diag 'Found library at: ' . $pkg->libpath;
diag 'Version: ' . $pkg->version;
diag 'License: ' . $pkg->license;
diag 'Header:  ' . $pkg->find_header('zlib.h');
diag 'Include dirs: ';
diag '     - ' . $_ for @{ $pkg->includedirs };
diag 'Lib:     ' . $pkg->libpath;
#
done_testing;
