use v5.40;
use FFI::Platypus 2.00;
use Alien::Zlib;

# The Build::Xrepo plugin's FFI gathering makes dynamic_libs point at the real
# shared library; feed it straight to FFI::Platypus.
my $alien = Alien::Zlib->new;
my $libs  = $alien->dynamic_libs;
die 'zlib not resolved; run `perl Makefile.PL && make` first' unless ref $libs eq 'ARRAY' && @$libs;
say 'Loaded zlib from: ' . $_ for @$libs;
my $ffi = FFI::Platypus->new( api => 2, lib => $libs, );

# const char * zlibVersion(void);
$ffi->attach( 'zlibVersion' => [] => 'string' );
say 'Platypus zlib version: ' . zlibVersion();
