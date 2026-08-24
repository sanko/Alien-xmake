use v5.40;
use Module::Build;
my $class = Module::Build->subclass( class => 'Alien::Xmake::Builder', code => <<'' );
use v5.40;
$|++;
sub ACTION_code ($s) {
    try {
        my $ver = 'v3.1.0';
        my $url = sprintf 'https://github.com/xmake-io/xmake/releases/download/%s/xmake-bundle-%s.cosmocc', $ver, $ver;
        $url = 'http://github.com/xmake-io/xmake/releases/download/v3.1.0/xmake-bundle-v3.1.0.cosmocc';
        my $xmk = File::Spec->catfile( @{$s->share_dir->{dist}}, 'xmake-bundle-'. $ver . '.cosmocc');
        warn $xmk;
        #~ File::Path::mkpath($s->share_dir->{dist}, 0, oct(755)) unless -d $s->share_dir;
        unless (-e $xmk && $s->is_executable($xmk)) {
            $s->log_verbose("Downloading $url... ");
            require HTTP::Tiny;
            my $http = HTTP::Tiny->new();
            # $args->{headers}{'if-modified-since'} ||= $http->_http_date($mtime) if -e $xmk and my $mtime = (stat($xmk))[9] ;
            my $tempfile = $xmk . int(rand(2**31));
            require Fcntl;
            sysopen my $fh, $tempfile, Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_WRONLY()
                or _croak(qq/Error: Could not create temporary file $tempfile for downloading: $!\n/);
            binmode $fh;
            my $response = $http->request('HEAD', $url, {
                data_callback => sub { warn 'data!'; print {$fh} $_[0] }
            });
            close $fh
                or _croak(qq/Error: Caught error closing temporary file $tempfile: $!\n/);
            if ( $response->{success} ) {
                rename $tempfile, $xmk
                    or _croak(qq/Error replacing $xmk with $tempfile: $!\n/);
                my $lm = $response->{headers}{'last-modified'};
                if ( $lm and my $mtime = $http->_parse_http_date($lm) ) {
                    utime $mtime, $mtime, $xmk;
                }
            }
            $response->{success} ||= $response->{status} eq '304';
            unlink $tempfile;
            return $response;
            $s->log_verbose('ok (' . (-s $xmk) .  " bytes) \n");
            $s->make_executable($xmk);
            system $xmk, '--help';
        }
    }
    catch($e) { }
    $s->SUPER::ACTION_code();
}

my $build = $class->new(
    module_name => 'Alien::Xmake',
    license     => 'artistic_2',
    dist_author => 'Sanko Robinson',
    requires    => { Carp => 0 },
    share_dir   => 'share'
);
$build->create_build_script;
