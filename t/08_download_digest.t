use v5.40;
use lib 'builder';
use Alien::Xmake::Builder;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Path::Tiny  qw[path];
use File::Temp  qw[tempdir];
use Digest::SHA qw[sha256_hex];
use experimental 'class';
#
my $tmp  = path( tempdir( CLEANUP => 1 ) );
my $file = $tmp->child('installer.bin');
$file->spew_raw("hello xmake\n");
my $actual = sha256_hex("hello xmake\n");
#
my $builder = eval { Alien::Xmake::Builder->new };
if ( !$builder ) {
    skip_all "Alien::Xmake::Builder failed to load: $@";
}
else {
    isa_ok $builder, ['Alien::Xmake::Builder'], 'Builder object';
    ok $builder->can('_verify_download'), 'has _verify_download';
}
subtest 'matching digest passes' => sub {
    my $asset = { digest => "sha256:$actual" };
    ok lives { $builder->_verify_download( $file, $asset ) }, 'valid sha256 digest is accepted';
};
subtest 'mismatched digest dies' => sub {
    my $asset = { digest => 'sha256:' . ( '0' x 64 ) };
    my $lives = lives { $builder->_verify_download( $file, $asset ) };
    my $err   = $@;
    ok !$lives, 'mismatched digest croaks';
    like "$err", qr/Checksum mismatch/, 'death mentions the mismatch';
    like "$err", qr/$actual/,           'death reports the computed hash';
};
subtest 'no digest skips' => sub {
    ok lives { $builder->_verify_download( $file, {} ) },    'asset without a digest is skipped';
    ok lives { $builder->_verify_download( $file, undef ) }, 'missing asset metadata is skipped';
};
subtest 'non-sha256 scheme skips' => sub {
    ok lives { $builder->_verify_download( $file, { digest => 'md5:abc123' } ) }, 'unsupported scheme is skipped';
};
#
done_testing;
