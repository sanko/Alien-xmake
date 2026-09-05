use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Alien::Xrepo;
use Capture::Tiny qw[capture];
use experimental 'class';
use Path::Tiny;
use Digest::MD5 qw[md5_hex];
use File::Temp ();
use Config;
#
my $repo = Alien::Xrepo->new( verbose => 0 );
my $xmake_exe = eval { Alien::Xmake->new->exe };
plan skip_all => 'no xmake available to exercise the recipe-override flow' unless $xmake_exe;

# A canary package that exists nowhere in the bundled xmake-repo. If the vendored
# recipe override is truly consulted end-to-end, `install` resolves it from the
# materialized local repository (registered in xmake's global cache), builds the
# trivial header-only install, and returns its PackageInfo. None of that can happen
# unless the override channel works, so success here is the end-to-end regression
# guard for recipe overrides.
my $dir = File::Temp::tempdir( 'xrepo-e2e-XXXX', CLEANUP => 1 );
my $recipe = path($dir)->child('canary_ttf.lua');
$recipe->spew(<<'LUA');
package("canary_ttf")
    set_license("MIT")
    on_install(function (package)
        os.mkdir(package:installdir("include"))
        io.writefile(path.join(package:installdir("include"), "canary_ttf.h"), "#define CANARY_TTF 1\n")
    end)
    on_test(function (package)
    end)
LUA

# The global cache key for this override set, mirroring _recipe_override_rc, so we
# can tear the registration down afterwards and never pollute the caller's xmake.
my $key = substr( md5_hex($recipe->slurp_raw), 0, 12 );

my $clean_done = 0;
sub _cleanup {
    return if $clean_done++;
    capture { system $xmake_exe, 'lua', '-c',
        "import('core.package.repository'); repository.remove('$key', true)" };
    $repo->uninstall( 'canary_ttf' );
}

subtest 'recipe override installs a package found nowhere else' => sub {
    my $info = eval { $repo->install( 'canary_ttf', undef, includes => [ $recipe->stringify ], kind => 'static' ) };
    if ( my $err = $@ ) {
        diag "xrepo install failed: $err";
        fail 'install with a vendored recipe override succeeds';
        diag 'The recipe override did not reach xmake: the materialized repo was not resolved.';
    }
    else {
        ok 1, 'install with a vendored recipe override succeeds';
    }
    ok $info, 'install returns package info';
    isa_ok $info, ['Alien::Xrepo::PackageInfo'], 'returned info is a PackageInfo';
    is $info->version, 'latest', 'version-less canary resolved to latest';
};

subtest 'override recipe actually landed: installed header is the trivial one' => sub {
    my $installdir = eval { $repo->fetch( 'canary_ttf', undef, kind => 'static' )->installdir };
    _cleanup();
    skip_all 'install never completed, nothing to check' unless $installdir && -d $installdir;
    my $header = path($installdir, 'include', 'canary_ttf.h');
    ok $header->is_file, "canary_ttf.h installed under $installdir";
    my $got = $header->slurp_raw;
    $got =~ s/\r\n/\n/g;
    is $got, "#define CANARY_TTF 1\n", 'installed header matches the overridden recipe';
};

done_testing;