use v5.40;
use strict;
use warnings;
use lib 'blib/lib', 'blib/arch';
use Cwd qw[getcwd abs_path];
use File::Temp qw[tempdir];
use Capture::Tiny qw[capture tee];
use Config;

my $target = $ENV{SPAWN_TARGET} // 'cmd';
#~ # Resolve a trivial Windows exe to exercise spawning without network: use
#~ # cmd.exe /c echo, and perl itself.
my $perl = $Config{perlpath};

# Which exe are we trying to spawn? cmd.exe is the most basic native exe.
my ($exe, @probe_args);
if ($target eq 'cmd') {
    $exe       = $ENV{COMSPEC} // 'C:\\Windows\\System32\\cmd.exe';
    @probe_args = ('/c', 'echo', 'PROBE_OK ' . time());
}
elsif ($target eq 'xmake') {
    require Alien::Xmake;
    my $x = Alien::Xmake->new;
    $exe = $x->exe;
}
else { die "unknown SPAWN_TARGET=$target\n"; }

my $cwd = getcwd;
my $short_tmp = tempdir();
my $long_tmp  = abs_path($short_tmp);   # try to expand away 8.3 short names

sub report {
    my ($name, $ok, $extra) = @_;
    printf "RESULT %-28s %s %s\n", $name, ($ok ? 'OK' : 'FAIL'), ($extra // '');
}

print "INFO cwd=$cwd\n";
print "INFO perl=$perl\n";
print "INFO exe=$exe\n";
print "INFO COMSPEC=$ENV{COMSPEC}\n";
print "INFO MSYSTEM=$ENV{MSYSTEM}\n" if $ENV{MSYSTEM};
print "INFO PATH=$ENV{PATH}\n";
print "INFO short_tmp=$short_tmp\n";
print "INFO long_tmp=$long_tmp\n";

# --- 1. system LIST (absolute, current cwd) ---
{
    my ($o, $e, $rc) = capture { system($exe, @probe_args) };
    report('system LIST abs', $rc == 0, "rc=$rc err=$! out=$o");
}

# --- 2. system { prog } LIST (indirect object) ---
{
    my ($o, $e, $rc) = capture { system { $exe } $exe, @probe_args };
    report('system {prog} abs', $rc == 0, "rc=$rc err=$!");
}

# --- 3. system STRING (goes through shell) ---
{
    my $quoted = $exe =~ s/"/\\"/gr;
    my ($o, $e, $rc) = capture { system "\"$quoted\" " . join(' ', map { /"/ ? "\"$_\"":$_ } @probe_args) };
    report('system STRING', $rc == 0, "rc=$rc err=$!");
}

# --- 4. backticks ---
{
    my $quoted = $exe =~ /"/ ? undef : $exe;
    my $out;
    my $rc;
    if (defined $quoted) {
        my $cmd = "\"$quoted\" " . join(' ', map { /"/ ? "\"$_\"" : $_ } @probe_args);
        $out = qx{$cmd};
        $rc  = $? >> 8;
    }
    report('backticks', $rc == 0, "rc=$rc out=$out");
}

# --- 5. open3 (IPC::Open3) ---
{
    require IPC::Open3;
    my $pid;
    my $out;
    my $rc;
    my $err;
    my $ok;
    eval {
        my $err_fh;
        open my $w, '>', \my $o;
        open $err_fh, '>', \my $er;
        $pid = IPC::Open3::open3(my $in, my $fh1, my $fh2, $exe, @probe_args);
        $out = do { local $/; <$fh1> // '' };
        close $in;
        waitpid($pid, 0);
        $rc = $? >> 8;
        $err = $er;
        $ok = 1;
    };
    report('IPC::Open3', $ok && $rc == 0, "rc=$rc err=" . ($err // ''));
}

# --- 6. Win32::Process with explicit cwd = short temp ---
{
    my $has = eval { require Win32::Process; 1 };
    if ($has) {
        my $p;
        my $ok = Win32::Process::Create($p, $exe, "\"$exe\" " . join(' ', @probe_args), 0, 8, $short_tmp);
        if ($ok) { $p->Wait(5000); report('Win32::Process cwd=short', 1, "cwd=$short_tmp"); }
        else     { report('Win32::Process cwd=short', 0, Win32::FormatMessage(Win32::GetLastError())); }
    }
    else { report('Win32::Process cwd=short', 'skip'); }
}

# --- 7. system LIST from short-temp cwd ---
{
    local $Cwd::cwd; # placeholder
    my $prev = getcwd;
    chdir $short_tmp or report('chdir short', 0, $!);
    my ($o, $e, $rc) = capture { system($exe, @probe_args) };
    chdir $prev;
    report('system LIST cwd=short', $rc == 0, "rc=$rc err=$! cwd=$short_tmp");
}

# --- 8. Win32::Process with explicit cwd = long temp ---
{
    my $has = eval { require Win32::Process; 1 };
    if ($has) {
        my $p;
        my $ok = Win32::Process::Create($p, $exe, "\"$exe\" " . join(' ', @probe_args), 0, 8, $long_tmp);
        if ($ok) { $p->Wait(5000); report('Win32::Process cwd=long', 1, "cwd=$long_tmp"); }
        else     { report('Win32::Process cwd=long', 0, Win32::FormatMessage(Win32::GetLastError())); }
    }
    else { report('Win32::Process cwd=long', 'skip'); }
}

# --- 9. Perl spawning a child perl (native-to-native, nested) ---
{
    my ($o, $e, $rc) = capture { system($perl, '-e', 'print qq(NESTED_OK)') };
    report('perl->perl system LIST', $rc == 0, "rc=$rc err=$!");
}

# --- 10. system LIST from long-temp cwd ---
{
    my $prev = getcwd;
    chdir $long_tmp or report('chdir long', 0, $!);
    my ($o, $e, $rc) = capture { system($exe, @probe_args) };
    chdir $prev;
    report('system LIST cwd=long', $rc == 0, "rc=$rc err=$! cwd=$long_tmp");
}

print "DONE\n";
