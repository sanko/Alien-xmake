use v5.40;
use blib;
use Test2::V0;
use File::Temp  qw[tempdir];
use File::Path  qw[make_path];
my $dir = tempdir();
#
use Alien::Xmake;
#
diag 'Working in ' . $dir;
my $xmake = Alien::Xmake->new;

{
    my $exe = $xmake->exe;
    qx[$exe g --theme=plain] if $ENV{AUTOMATED_TESTING};
    chdir $dir;

    # Build the project by hand instead of `xmake create`: on some Windows CI
    # runners the generated template files are read-only and its comment block
    # embeds shell-style '$' lines that xmake's Lua parser rejects.  Writing a
    # fresh, clean project sidesteps both problems.
    my $proj = 'test_cpp';
    make_path("$proj/src");
    {
        open my $fh, '>', "$proj/xmake.lua" or die "cannot write xmake.lua: $!";
        print {$fh} "add_rules(\"mode.debug\", \"mode.release\")\ntarget(\"test_cpp\")\n    set_kind(\"binary\")\n    add_files(\"src/*.cpp\")\n";
        close $fh;
        open my $mh, '>', "$proj/src/main.cpp" or die "cannot write main.cpp: $!";
        print {$mh} "#include <cstdio>\nint main(void) {\n    std::printf(\"hello world!\\n\");\n    return 0;\n}\n";
        close $mh;
    }
    ok( ( -d "$proj/src" ), 'project source created' );

    chdir $proj;

    if ( $^O eq 'MSWin32' ) {
        diag qx[$exe f -p windows -m msvc -y 2>&1];
    }

    subtest compile => sub {
        diag 'Building project..';
        my $build = `$exe --quiet 2>&1`;
        is $?, 0, 'project built';
        diag $build;
        my $run = `$exe run 2>&1`;
        like $run, qr[hello world!], 'project says hello';
        diag $run;
    }
}
#
done_testing;
