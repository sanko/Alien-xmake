use v5.40;
use blib;
use Test2::V0;
use File::Temp    qw[tempdir];
use Capture::Tiny qw[capture];
my $dir = tempdir();
#
use Alien::Xmake;
#
diag 'Working in ' . $dir;
my $xmake = Alien::Xmake->new;

subtest xrepo => sub {
    my $exe = $xmake->exe;
    #~ my ( $stdout, $stderr, $exit ) = capture { system $exe, 'lua', 'private.xrepo', '--version' };
    diag join ' ', $exe, qw[create --quiet --project=test_cpp --language=c++ --template=console];
    diag `$exe create --quiet --project=test_cpp --language=c++ --template=console`;
    pass 'ok?';
};

{
    # Resolve xmake by bare name from PATH (module prepends its bin dir) so the
    # spawned process doesn't receive an absolute D:\... path, which a git-bash
    # runner can refuse to spawn.
    my ( $xm ) = $xmake->_run_base;
    qx[$xm g --theme=plain] if $ENV{AUTOMATED_TESTING};
    chdir $dir;
    my ( $stdout, $stderr, $exit ) = capture { system { $xm } $xm, qw[create --quiet --project=test_cpp --language=c++ --template=console] };
    ok( ( -d 'test_cpp' ), 'project created' );

    #~ ok !$exit, 'project created';
    diag $stdout if $exit && length $stdout;
    diag $stderr if $exit && length $stderr;
    chdir 'test_cpp';
    subtest compile => sub {
        my $todo = todo 'Require a working compiler';    # outside the scope of Alien::Xmake
        diag 'Building project..';
        ( $stdout, $stderr, $exit ) = capture { system { $xm } $xm, '--quiet' };
        ok !$exit, 'project built';
        diag $stdout if $exit && length $stdout;
        diag $stderr if $exit && length $stderr;
        ( $stdout, $stderr, $exit ) = capture { system { $xm } $xm, 'run' };
        ok $stdout =~ /hello world!/, 'project says hello';
        diag $stdout if $exit && length $stdout;
        diag $stderr if $exit && length $stderr;
    }
}
#
done_testing;
