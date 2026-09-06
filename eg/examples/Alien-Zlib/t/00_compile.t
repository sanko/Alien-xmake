use v5.40;
use blib;
use Test2::V0;
use Alien::Zlib;
my $zlib = Alien::Zlib->new;
isa_ok $zlib, ['Alien::Zlib'];
isa_ok $zlib, ['Alien::Base'];
ok( defined( $zlib->install_type // () ), 'install_type resolves' );
done_testing;
