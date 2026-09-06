use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Test::Alien::Build qw[alienfile alienfile_ok];
use File::Temp qw[tempdir];
use Path::Tiny;
use Alien::Xrepo;
use experimental 'class';

my $store = Path::Tiny->tempdir->stringify;

# Spy engine: same contract as Alien::Xrepo; export lays down a fake package
# tree (include/lib/bin) so the plugin has something to assemble.  %FAIL makes
# install die for a package, driven by a package global so the plugin can be
# injected as a plain class name.
my %FAIL;
class Alien::Build::Plugin::Build::Xrepo::TestSpy {
    our %FAIL;
    field $calls : param = [];

    method install ( $name, $version, %opts ) {
        push @$calls, { action => 'install', name => $name, version => $version, opts => {%opts} };
        die "boom on $name" if $FAIL{$name};
        return $self->_pkg( $name, $version );
    }

    method fetch ( $name, $version, %opts ) {
        push @$calls, { action => 'fetch', name => $name, version => $version, opts => {%opts} };
        return $self->_pkg( $name, $version );
    }

    method info ( $name, %opts ) {
        push @$calls, { action => 'info', name => $name, opts => {%opts} };
        return {};
    }

    method export ( $name, $version, %opts ) {
        push @$calls, { action => 'export', name => $name, version => $version, opts => {%opts} };
        my $t = Path::Tiny->new( $opts{packagedir} // return 0 );
        $t->child('include')->mkpath;
        $t->child('lib')->mkpath;
        $t->child('bin')->mkpath;
        $t->child('include')->child("$name.h")->spew_utf8("#define $name 1\n");
        $t->child('lib')->child("$name.lib")->spew_utf8("LIB\n");
        $t->child('bin')->child("$name.dll")->spew_utf8("BIN\n");
        return 1;
    }

    method add_repo ( $name, $url ) {
        push @$calls, { action => 'add_repo', name => $name, url => $url };
    }

    method calls () { return $calls }

    method _pkg ( $name, $version ) {
        return Alien::Xrepo::PackageInfo->new(
            includedirs => ["$store/$name/include"],
            libfiles    => ["$store/$name/bin/$name.dll"],
            license     => undef,
            linkdirs    => ["$store/$name/lib"],
            links       => [$name],
            shared      => 1,
            static      => 0,
            version     => $version // '1.2.3',
            installdir  => "$store/$name",
            kind        => 'library',
        );
    }
}

sub sf ( $packages, %opts ) {
    my $text = "use alienfile;\nplugin 'Build::Xrepo' => (\n  packages => $packages,\n";
    $text .= "  ffi => $opts{ffi},\n" if $opts{ffi};
    $text .= "  version => '$opts{version}',\n" if $opts{version};
    $text .= "  kind => '$opts{kind}',\n" if $opts{kind};
    $text .= "  repo => 'Alien::Build::Plugin::Build::Xrepo::TestSpy',\n";
    $text .= ");\n";
    return $text;
}

sub driven_build ( $text ) {
    my $dir = tempdir( CLEANUP => 1 );
    my $build = alienfile_ok( $text, stage => "$dir/stage", prefix => "$dir/prefix", root => "$dir/root" );
    return { dir => $dir, build => $build } unless $build;
    ok $build, 'alienfile compiles';
    is $build->probe, 'share', 'probe ends in a share install';
    $build->download;
    $build->build;
    return { dir => $dir, build => $build };
}

sub winslash { my $s = shift; $s =~ s{\\}{/}g; $s }

subtest 'share install assembles and gathers a single package' => sub {
    my $r = driven_build( sf( "['zstd']" ) );
    my $build = $r->{build};
    my $dir   = $r->{dir};
    my $rp    = $build->runtime_prop;

    is $rp->{install_type}, 'share', 'install_type recorded';

    my $cflags = winslash( $rp->{cflags} );
    like $cflags, qr/-I[^\s]*zstd\/include/, 'primary include flags present';
    my $pfx = winslash( $rp->{prefix} );
    like $cflags, qr{\Q$pfx\E}, 'flags reference the final prefix';

    my $libs = winslash( $rp->{libs} );
    like $libs, qr/-L[^\s]*zstd\/lib/, 'primary lib flags present';
    like $libs, qr/zstd\.lib\b|\-lzstd/, 'primary link flags present';

    is $rp->{version}, '1.2.3', 'version gathered';

    ok -e "$build->{install_prop}{prefix}/zstd/include/zstd.h", 'package tree copied into the stage';
    ok -e "$build->{install_prop}{prefix}/bin/zstd.dll",        'bin dir merged into stage/bin';

    my $bins = [ map { winslash($_) } @{ $rp->{bin_dir} } ];
    is $bins, ["$pfx/zstd/bin"], 'bin_dir re-rooted to the final prefix';

    my $it = $build->meta->interpolator;
    ok $it->has_helper('xrepo'),             'xrepo helper registered';
    ok $it->has_helper('xmake'),             'xmake helper registered';
    ok $it->has_helper('xrepo_cflags'),      'xrepo_cflags helper registered';
    ok $it->has_helper('xrepo_libs'),        'xrepo_libs helper registered';
    ok $it->has_helper('xrepo_version'),     'xrepo_version helper registered';
    ok $it->has_helper('xrepo_dynamic_libs'), 'xrepo_dynamic_libs helper registered';

    like $it->interpolate( '%{xrepo_version}', $build ), qr/1\.2\.3/, 'helper reads runtime props';
};

subtest 'multi-package recipe populates alt with the ambient profile' => sub {
    my $r = driven_build( sf( "['zstd', { name => 'libsdl3', kind => 'shared' }]", version => '3.14.0' ) );
    my $build = $r->{build};
    my $rp    = $build->runtime_prop;

    like winslash( $rp->{cflags} ), qr/-I[^\s]*zstd\/include/, 'primary cflags set';
    like winslash( $rp->{alt}{libsdl3}{libs} ), qr/zstd|libsdl3/,
        'alt libs present';
    is $rp->{alt}{libsdl3}{version}, '3.14.0', 'ambient version folded into the alt package';
    ok !exists $rp->{alt}{zstd}, 'primary package is not duplicated in alt';
};

subtest 'failure of a sibling isolates the gather' => sub {
    $Alien::Build::Plugin::Build::Xrepo::TestSpy::FAIL{libsdl3} = 1;
    my $r = driven_build( sf( "['zstd', { name => 'libsdl3' }, 'ninja']" ) );
    my $build = $r->{build};
    my $rp    = $build->runtime_prop;
    delete $Alien::Build::Plugin::Build::Xrepo::TestSpy::FAIL{libsdl3};

    my $errors = $build->install_prop->{xrepo}{errors};
    like $errors->{libsdl3}, qr/boom/, 'failed sibling recorded in errors';

    like winslash( $rp->{cflags} ), qr/-I[^\s]*zstd\/include/,
        'primary package still gathered';
    ok exists $rp->{alt}{ninja},       'sibling after the failure gathered in alt';
    ok !exists $rp->{alt}{libsdl3},    'failed sibling omitted from alt';
    is $build->install_type, 'share', 'a partial success is still a share install';
};

subtest 'ffi gathers a name and dynamic libs' => sub {
    my $r = driven_build( sf( "['zstd']", ffi => 1 ) );
    my $build = $r->{build};
    my $rp    = $build->runtime_prop;

    is $rp->{ffi_name}, 'zstd', 'ffi_name from the primary links';
    ok scalar @{ $rp->{dynamic_libs} } >= 1, 'dynamic libs listed';
    ok scalar grep { /zstd\.dll/ } @{ $rp->{dynamic_libs} }, 'dynamic libs name the package dll';
};

subtest 'missing packages is rejected at alienfile compile' => sub {
    my $dir = Path::Tiny->tempdir;
    like
        dies {
            alienfile( source => "use alienfile;\nplugin 'Build::Xrepo';\n",
                       stage => "$dir/stage", prefix => "$dir/prefix", root => "$dir/root" );
        },
        qr/packages/,
        'packages is a required property';
};

done_testing;