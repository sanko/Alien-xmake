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
    my $exe = $xmake->exe;
    qx[$exe g --theme=plain] if $ENV{AUTOMATED_TESTING};
    chdir $dir;
    #~ my ( $stdout, $stderr, $exit ) = capture { system join ' ', $exe, qw[create --quiet --project=test_cpp --language=c++ --template=console] };
    diag `$exe create --quiet --project=test_cpp --language=c++ --template=console`;

    ok( ( -d 'test_cpp' ), 'project created' );

    #~ ok !$exit, 'project created';
    #~ diag $stdout if $exit && length $stdout;
    #~ diag $stderr if $exit && length $stderr;
    chdir 'test_cpp';
    subtest compile => sub {
        #~ my $todo = todo 'Require a working compiler';    # outside the scope of Alien::Xmake
        diag 'Building project..';
        diag `$exe --quiet`;
        #~ ok !$exit, 'project built';
        #~ diag $stdout if $exit && length $stdout;
        #~ diag $stderr if $exit && length $stderr;
        diag `$exe run`;
        like `$exe run`, qr[hello world!], 'project says hello';
    }
}
#
done_testing;
