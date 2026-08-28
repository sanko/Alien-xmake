use v5.40;
use blib;
use Alien::Xmake;

my @work = eval { ( 'bin', Alien::Xmake->new->_resolve_path ) };
my $bin = $work[1] // '';

print "resolved xmake binary: ", ( $bin || '(none)' ), "\n";

sub pe_machine ($file) {
    open my $fh, '<:raw', $file or return undef;
    seek $fh, 0x3C, 0;
    read( $fh, my $pe_off, 4 ) == 4 or return undef;
    my $off = unpack( 'V', $pe_off );
    seek $fh, $off, 0;
    read( $fh, my $sig, 4 ) == 4 or return undef;
    return undef unless $sig eq "PE\0\0";
    read( $fh, my $mach, 2 ) == 2 or return undef;
    unpack( 'v', $mach );
}

if ( -e $bin || -x $bin ) {
    my %mach = (
        0x8664 => 'x64 (AMD64)',
        0xAA64 => 'ARM64',
        0x014c => 'x86 (i386)',
        0x01c4 => 'ARM (ARM32)',
    );
    my $m = pe_machine($bin);
    print "installed PE machine type: ", ( defined $m ? sprintf( '0x%04X', $m ) . " = " . ( $mach{$m} // 'unknown' ) : 'not a PE file / unreadable' ), "\n";
}
else {
    print "binary does not exist / not executable\n";
}

if ( defined $bin && -e $bin ) {
    my $run = sub (@a) {
        print "\n--- xmake @{[ join ' ', @a ]} ---\n";
        my $rc = system $bin, @a;
        print "(exit ", ( $rc >> 8 ), ")\n" if $rc != 0;
    };
    $run->('--version');
    $run->( 'lua', '-c', 'print(os.arch())' );
}
1;
