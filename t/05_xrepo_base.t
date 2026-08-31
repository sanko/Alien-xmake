use v5.40;
use feature 'class';
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Path::Tiny qw[path cwd];
use Alien::Xrepo::Base;
use File::Temp qw[tempdir];
no warnings qw[experimental::class];


# Test package
class Alien::Xrepo::TestPackage : isa(Alien::Xrepo::Base) {
    method package_name {'zlib'}
}

# A subclass that overrides the default install options
class Alien::Xrepo::TestPackageWithOpts : isa(Alien::Xrepo::Base) {
    method package_name {'zlib'}
    method install_opts { return ( kind => 'shared' ); }
}
my $tmp = path( tempdir( CLEANUP => 1 ) );
#
my $alien = Alien::Xrepo::TestPackage->new( root => $tmp, verbose => 1 );
isa_ok $alien, ['Alien::Xrepo::Base'], 'isa Alien::Xrepo::Base';

# Delegation before any installation returns safe defaults
subtest 'pre-install delegation' => sub {
    my $fresh = Alien::Xrepo::TestPackage->new( root => $tmp, verbose => 0 );
    is $fresh->libpath,               undef, 'libpath is undef before install';
    is $fresh->ffi_lib,               undef, 'ffi_lib is undef before install';
    is $fresh->version,               undef, 'version is undef before install';
    is $fresh->kind,                  undef, 'kind is undef before install';
    is $fresh->cflags,                '',    'cflags is empty before install';
    is $fresh->libs,                  '',    'libs is empty before install';
    is $fresh->bin_dir,               [],    'bin_dir is empty before install';
    is $fresh->find_header('zlib.h'), undef, 'find_header is undef before install';
    is $fresh->package_info,          undef, 'package_info is undef before install';
};

# Test install
my $info = $alien->install;
ok $info,           'Installed package';
ok $alien->libpath, 'Got libpath: ' . $alien->libpath;
ok $alien->ffi_lib, 'Got ffi_lib';
ok $alien->cflags,  'Got cflags: ' . $alien->cflags;
ok $alien->libs,    'Got libs: ' . $alien->libs;
is $alien->kind, 'library', 'Kind is library';
ok $alien->version, 'Got version: ' . $alien->version;

# package_info returns the underlying metadata object
my $pi = $alien->package_info;
isa_ok $pi, ['Alien::Xrepo::PackageInfo'], 'package_info returns PackageInfo';
is $pi->version, $alien->version, 'package_info version matches delegation';
is $pi->kind,    $alien->kind,    'package_info kind matches delegation';
is $pi->libpath, $alien->libpath, 'package_info libpath matches delegation';
like $alien->cflags, qr{-I}, 'cflags include at least one -I include flag';
my $cflag_inc_count = () = $alien->cflags =~ /-I/g;
is $cflag_inc_count, scalar @{ $pi->includedirs }, 'one -I flag per includedir';

# bin_dir is empty for a library-type package
is $alien->bin_dir, [], 'bin_dir is empty for a library package';

# Idempotency: installing again reuses the cached package
my $info2 = $alien->install;
ok $info2,          'Install is idempotent';
ok $info2->libpath, 'Re-installed package has a libpath';

# Test delegation and headers
my $header = $alien->find_header('zlib.h');
ok $header,    'Found zlib.h';
ok -f $header, 'Header file exists';

# Test that a missing header returns undef
my $missing = $alien->find_header('does_not_exist.h');
ok !defined $missing, 'find_header returns undef for a missing header';

# Test version_constraint via a dedicated subclass
subtest 'version constraint' => sub {
    my $constrained = Alien::Xrepo::TestPackage->new( root => $tmp, verbose => 0, version_constraint => '1.3.x' );
    my $cinfo       = $constrained->install;
    ok $cinfo,                       'Installed with version constraint';
    ok $cinfo->version =~ /^v?1\.3/, 'Version satisfies 1.3.x constraint: ' . $cinfo->version;
};
subtest 'with binary package' => sub {

    class Alien::Xrepo::TestBin : isa(Alien::Xrepo::Base) {
        method package_name {'ninja'}
    }
    my $alien_bin = Alien::Xrepo::TestBin->new( root => $tmp, verbose => 1 );
    my $info_bin  = $alien_bin->install;
    ok $info_bin, 'Installed ninja';
    is $alien_bin->kind, 'binary', 'Kind is binary';
    ok $alien_bin->bin_dir,      'Got bin_dir';
    ok @{ $alien_bin->bin_dir }, 'bin_dir is not empty';
    is $alien_bin->bin_dir, $alien_bin->package_info->bin_dir, 'bin_dir matches package_info';

    # Upgrade (verify it runs without error)
    ok $alien_bin->upgrade, 'Upgrade ninja';
};

# install_opts is respected during the Builder phase; at runtime install
# still succeeds with the explicit opts passed to install()
subtest install_opts => sub {
    my $with_opts = Alien::Xrepo::TestPackageWithOpts->new( root => $tmp, verbose => 0 );
    ok $with_opts->can('install_opts'), 'subclass implements install_opts';
    my $optinfo = $with_opts->install;
    ok $optinfo, 'Installed package with install_opts';
    is $optinfo->kind, 'library', 'Shared library kind after install with opts';
};
#
done_testing;
