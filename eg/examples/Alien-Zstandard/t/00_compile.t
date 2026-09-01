use v5.40;

BEGIN {
    require lib;
    lib->import('lib');
    eval { require blib; 1 };    # add blib/lib + blib/arch if a build exists
}
use Test2::V0;
use Alien::Zstandard;
my $zstd = Alien::Zstandard->new;
isa_ok $zstd, ['Alien::Zstandard'],   'isa Alien::Zstandard';
isa_ok $zstd, ['Alien::Xrepo::Base'], 'isa Alien::Xrepo::Base';
is $zstd->package_name, 'zstd', 'package_name is zstd';
done_testing;
