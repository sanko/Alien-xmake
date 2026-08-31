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
