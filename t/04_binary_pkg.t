use v5.40;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use blib;
use Alien::Xrepo;
use Path::Tiny;

skip_all 'xmake lua private.xrepo is broken on the Windows runner (exit 255, no output)' if $^O eq 'MSWin32';
my $repo = Alien::Xrepo->new( verbose => 1 );

# Install ninja (binary)
my $pkg = $repo->install('ninja');
ok( $pkg, 'Installed ninja' );
is( $pkg->kind, 'binary', 'Package kind is binary' );
ok( $pkg->bin_dir, 'Found bin_dir' );
diag "Bin dirs: " . join( ', ', @{ $pkg->bin_dir } );
my $ninja_found = 0;
for my $dir ( @{ $pkg->bin_dir } ) {
    my $exe = path($dir)->child( $^O eq 'MSWin32' ? 'ninja.exe' : 'ninja' );
    if ( $exe->exists ) {
        $ninja_found = 1;
        diag "Found ninja at $exe";
        last;
    }
}
ok( $ninja_found, 'Ninja executable found in bin_dir' );
done_testing;
