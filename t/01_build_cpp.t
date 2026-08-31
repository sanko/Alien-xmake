use v5.40;
use blib;
use Test2::V0;
use File::Temp   qw[tempdir];
my $dir = tempdir();
#
use Alien::Xmake;
#
diag 'Working in ' . $dir;
my $xmake = Alien::Xmake->new;

subtest xrepo => sub {
    my $exe = $xmake->exe;
    diag join ' ', $exe, qw[create --quiet --project=test_cpp --language=c++ --template=console];
    diag `$exe create --quiet --project=test_cpp --language=c++ --template=console 2>&1`;
    pass 'ok?';
};

{
    my $exe = $xmake->exe;
    qx[$exe g --theme=plain] if $ENV{AUTOMATED_TESTING};
    chdir $dir;
    diag `$exe create --quiet --project=test_cpp --language=c++ --template=console 2>&1`;

    ok( ( -d 'test_cpp' ), 'project created' );

    chdir 'test_cpp';

    # xmake's generated xmake.lua template embeds shell-style '$' lines in a
    # comment block that xmake's Lua parser chokes on in some Windows
    # environments.  Replace it with a minimal, comment-free config so the
    # project always parses, then pin MSVC on Windows (auto-detection would
    # otherwise latch onto Git's broken mingw64 on the CI runner).
    my $lua = <<'LUA';
add_rules("mode.debug", "mode.release")
target("test_cpp")
    set_kind("binary")
    add_files("src/*.cpp")
LUA
    open my $fh, '>', 'xmake.lua' or die "cannot write xmake.lua: $!";
    print {$fh} $lua;
    close $fh;

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
