use v5.40;
BEGIN {
    require lib; lib->import('lib');
    eval { require blib; 1 };    # add blib/lib + blib/arch if a build exists
}
use Test2::V0;
use Alien::lsquic;

my $lsquic = Alien::lsquic->new;
isa_ok $lsquic, ['Alien::lsquic'], 'isa Alien::lsquic';
isa_ok $lsquic, ['Alien::Xrepo::Base'], 'isa Alien::Xrepo::Base';
is $lsquic->package_name, 'lsquic', 'package_name is lsquic';

done_testing;