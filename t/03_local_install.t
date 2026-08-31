use v5.40;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Alien::Xrepo;
use Path::Tiny;
use File::Temp qw[tempdir];

#
my $tmp  = path( tempdir( CLEANUP => 1 ) );
my $repo = Alien::Xrepo->new( root => $tmp, verbose => 1 );
ok -d $tmp, 'Root directory created';
is $ENV{XMAKE_CONFIGDIR},      $tmp->child('.xmake')->absolute->stringify,   'XMAKE_CONFIGDIR set';
is $ENV{XMAKE_PKG_INSTALLDIR}, $tmp->child('packages')->absolute->stringify, 'XMAKE_PKG_INSTALLDIR set';

# Try to install something small
my $pkg = $repo->install('zlib');
ok $pkg,                                              'Installed zlib locally';
ok $pkg->libpath,                                     'Found libpath';
ok $tmp->subsumes( path( $pkg->libpath )->absolute ), 'libpath is inside local root';
#
done_testing;
