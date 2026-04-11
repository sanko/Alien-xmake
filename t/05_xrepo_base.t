use v5.40;
use feature 'class';
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Path::Tiny qw[path cwd];
use Alien::Xrepo::Base;
use File::Temp qw[tempdir];
no warnings 'experimental::class';

# Test package
class Alien::Xrepo::TestPackage : isa(Alien::Xrepo::Base) {
    method package_name {'zlib'}
}
my $tmp = path( tempdir( CLEANUP => 1 ) );
#
my $alien = Alien::Xrepo::TestPackage->new( root => $tmp, verbose => 1 );
isa_ok $alien, ['Alien::Xrepo::Base'], 'isa Alien::Xrepo::Base';

# Test install
my $info = $alien->install;
ok $info,           'Installed package';
ok $alien->libpath, 'Got libpath: ' . $alien->libpath;
ok $alien->ffi_lib, 'Got ffi_lib';
ok $alien->cflags,  'Got cflags: ' . $alien->cflags;
ok $alien->libs,    'Got libs: ' . $alien->libs;
is $alien->kind, 'library', 'Kind is library';
ok $alien->version, 'Got version: ' . $alien->version;

# Test delegation and headers
my $header = $alien->find_header('zlib.h');
ok $header,    'Found zlib.h';
ok -f $header, 'Header file exists';

# Test with a binary package
class Alien::Xrepo::TestBin : isa(Alien::Xrepo::Base) {
    method package_name {'ninja'}
}
my $alien_bin = Alien::Xrepo::TestBin->new( root => $tmp, verbose => 1 );
my $info_bin  = $alien_bin->install;
ok $info_bin, 'Installed ninja';
is $alien_bin->kind, 'binary', 'Kind is binary';
ok $alien_bin->bin_dir,      'Got bin_dir';
ok @{ $alien_bin->bin_dir }, 'bin_dir is not empty';

# Test upgrade (at least verify it runs)
ok $alien_bin->upgrade, 'Upgrade ninja';
#
done_testing;
