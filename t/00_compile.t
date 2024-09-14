use strict;
use warnings;
use lib 'lib', '../blib/lib', '../lib';
use Test2::V0;

#~ use Env qw[@PATH];
#
use Alien::xmake;

#~ diag File::ShareDir::dist_dir('Affix-xmake');
#~ use Data::Dump;
#~ ddx \@INC;
#~ my ($dir) = grep {defined} map {my $path = path($_)->child(qw[auto share dist Alien-xmake]); $path->is_dir ? $path : ()} @INC;
#~ ddx $dir;
#~ ...;
#~ use Path::Tiny qw[path];
#~ my $path = path $INC{'Alien/xmake.pm'};
#~ diag $path->parent;
#
diag 'Install type: ' . Alien::xmake->install_type;

#~ unshift @PATH, Alien::xmake->bin_dir;
#
subtest xmake => sub {
    my $exe = Alien::xmake->exe;
    diag 'Path to exe:  ' . $exe;
    ok `$exe --version`, $exe . ' --version';
};
#
subtest xrepo => sub {
    my $exe = Alien::xmake->xrepo;
    diag 'Path to exe:  ' . $exe;
    ok `$exe --version`, $exe . ' --version';
};
ok( Alien::xmake->version, Alien::xmake->version );
#
done_testing;
