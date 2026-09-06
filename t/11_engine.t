use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use File::Temp qw[tempdir];
use JSON::PP   qw[decode_json];
use Path::Tiny;
use Alien::Xrepo;
use Alien::Xrepo::Build;
use Alien::Xrepo::Build::Recipe;
use experimental 'class';

# Spy repo: records every call instead of talking to xrepo. `preinstalled` maps
# package => version for the probe stage; `fail` makes install die for a package.
class Alien::Xrepo::Build::TestSpy {
    field $calls        : param = [];
    field $preinstalled : param = {};
    field $fail         : param = {};

    method install ( $name, $version, %opts ) {
        push @$calls, { action => 'install', name => $name, version => $version, opts => {%opts} };
        die "boom on $name" if $fail->{$name};
        return $self->_pkg( $name, $version );
    }

    method fetch ( $name, $version, %opts ) {
        push @$calls, { action => 'fetch', name => $name, version => $version, opts => {%opts} };
        return $self->_pkg( $name, $version );
    }

    method info ( $name, %opts ) {
        push @$calls, { action => 'info', name => $name, opts => {%opts} };
        my $v = $preinstalled->{$name};
        return $v ? { version => $v } : {};
    }

    method export ( $name, $version, %opts ) {
        push @$calls, { action => 'export', name => $name, version => $version, opts => {%opts} };
        return 1;
    }

    method add_repo ( $name, $url ) {
        push @$calls, { action => 'add_repo', name => $name, url => $url };
    }
    method calls () { return $calls }

    method _pkg ( $name, $version ) {
        return Alien::Xrepo::PackageInfo->new(
            includedirs => ["/tmp/store/$name/include"],
            libfiles    => [],
            license     => undef,
            linkdirs    => [],
            links       => [],
            shared      => 1,
            static      => 0,
            version     => $version // '1.2.3',
            installdir  => "/tmp/store/$name",
            kind        => 'library',
        );
    }
}
my $dir = tempdir( CLEANUP => 1 );

sub build ( $packages, %opts ) {
    my $recipe = Alien::Xrepo::Build::Recipe->new( packages => $packages, %{ $opts{recipe_extra} // {} } );
    delete $opts{recipe_extra};
    return Alien::Xrepo::Build->new( recipe => $recipe, %opts );
}
subtest 'configure freezes recipe and folds ambient opts' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new;
    my $b   = build( [ 'zstd', { name => 'libsdl3', kind => 'shared' } ], repo => $spy, root => '/tmp/store', );
    my @hook_calls;
    $b->register_hook( configure => sub { push @hook_calls, 1 } );
    $b->configure( kind => 'static' );
    ok !defined $b->meta_prop->{name}, 'name stays undef unless recipe names it';
    is $b->meta_prop->{packages},                    [qw[zstd libsdl3]], 'meta lists packages';
    is $b->meta_prop->{package_defs}{libsdl3}{kind}, 'shared',           'meta captures defs';
    is $b->install_prop->{profile}{kind},            'static',           'ambient option folded into profile';
    is $b->install_prop->{store},                    '/tmp/store',       'store root resolved';
    is $b->install_type,                             'system',           'nothing installed yet';
    is $b->stage_done->{configure},                  1,                  'configure stage marked done';
    is scalar @hook_calls,                           1,                  'configure hook ran';
};
subtest 'probe marks satisfied packages and install skips them' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new( preinstalled => { zstd => '1.5.6' } );
    my $b   = build( [ { name => 'zstd', version => '1.5.6' }, 'libsdl3' ], repo => $spy, );
    $b->run;
    my %by_action = map { $_->{action} => 1 } @{ $spy->calls };
    ok $by_action{info}, 'probe asked xrepo for each package';
    is $b->install_prop->{probed}{zstd}{satisfied},    1, 'matching version satisfied';
    is $b->install_prop->{probed}{libsdl3}{satisfied}, 0, 'no store hit for libsdl3';
    my (@installs) = grep { $_->{action} eq 'install' } @{ $spy->calls };
    is scalar @installs,   1,         'only the unsatisfied package was installed';
    is $installs[0]{name}, 'libsdl3', 'skip hit the right package';
    is $b->install_type,   'share',   'a fetched package flips install_type';
};
subtest 'probe_policy always reinstalls despite a hit' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new( preinstalled => { zstd => '1.5.6' } );
    my $b   = build( ['zstd'], repo => $spy, probe_policy => 'always' );
    $b->run;
    my (@installs) = grep { $_->{action} eq 'install' } @{ $spy->calls };
    is scalar @installs, 1, 'always policy installed anyway';
};
subtest 'probe_policy off never probes' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new;
    my $b   = build( ['zstd'], repo => $spy, probe_policy => 'off' );
    $b->run;
    my (@infos) = grep { $_->{action} eq 'info' } @{ $spy->calls };
    is scalar @infos, 0, 'no probe calls with policy off';
    ok !$b->install_prop->{probed}{zstd}, 'no probe data recorded';
};
subtest 'a failed package isolates: siblings install, error recorded' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new( fail => { libsdl3 => 1 } );
    my $b   = build( [ 'zstd', { name => 'libsdl3' }, 'ninja' ], repo => $spy, probe_policy => 'off' );
    $b->run;
    my (@installs) = grep { $_->{action} eq 'install' } @{ $spy->calls };
    is scalar @installs, 3, 'all packages attempted';
    like $b->runtime_prop->{errors}{libsdl3}, qr/boom/, 'failure captured in runtime_prop';
    ok exists $b->runtime_prop->{packages}{zstd},  'sibling before the failure installed';
    ok exists $b->runtime_prop->{packages}{ninja}, 'sibling after the failure installed';
    is $b->install_type, 'share', 'a partial success is still a share install';
};
subtest 'gather fetches anything the install did not produce' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new;
    my $b   = build( ['zstd'], repo => $spy, probe_policy => 'off' );
    $b->install;
    $b->gather;
    my (@fetches) = grep { $_->{action} eq 'fetch' } @{ $spy->calls };
    is scalar @fetches,                             0,       'gather skips packages already gathered by install';
    is $b->runtime_prop->{packages}{zstd}{version}, '1.2.3', 'runtime data present';
    my $spy2 = Alien::Xrepo::Build::TestSpy->new;
    my $b2   = build( ['zstd'], repo => $spy2, probe_policy => 'off' );
    $b2->gather;
    my (@f2) = grep { $_->{action} eq 'fetch' } @{ $spy2->calls };
    is scalar @f2, 1, 'gather fetches when install never ran';
};
subtest 'export writes the runtime snapshot' => sub {
    my $snap = path($dir)->child('snapshot.json');
    my $spy  = Alien::Xrepo::Build::TestSpy->new;
    my $b    = build( [ { name => 'zstd', version => '1.5.6' } ], repo => $spy, probe_policy => 'off', snapshot => $snap );
    $b->run;
    ok -e $snap, 'snapshot file written';
    my $data = decode_json( $snap->slurp_utf8 );
    is $data->{install_type},               'share',           'snapshot records install_type';
    is $data->{packages}{zstd}{version},    '1.5.6',           'snapshot records runtime data';
    is $data->{packages}{zstd}{installdir}, '/tmp/store/zstd', 'snapshot records installdir';
};
subtest 'checkpoint/resume skips completed work' => sub {
    my $cp  = path($dir)->child('state.json');
    my $spy = Alien::Xrepo::Build::TestSpy->new;
    my $b   = build( ['zstd'], repo => $spy, probe_policy => 'off', checkpoint => $cp );
    $b->run;
    my $calls_after_first = scalar @{ $spy->calls };
    ok $calls_after_first > 0, 'first run made calls';
    ok -e $cp,                 'checkpoint file written';
    my $spy2      = Alien::Xrepo::Build::TestSpy->new;
    my $b2        = build( ['zstd'], repo => $spy2, probe_policy => 'off', checkpoint => $cp, resume => 1 );
    my @installs2 = grep { $_->{action} eq 'install' } @{ $spy2->calls };
    is scalar @installs2,                            0,       'resume did not reinstall';
    is $b2->install_type,                            'share', 'resumed build kept prior install_type';
    is $b2->runtime_prop->{packages}{zstd}{version}, '1.2.3', 'resumed build kept runtime data';
    is $b2->stage_done->{install},                   1,       'resumed build knows install completed';
};
subtest 'hooks run for every registered stage' => sub {
    my $spy = Alien::Xrepo::Build::TestSpy->new;
    my $b   = build( ['zstd'], repo => $spy, probe_policy => 'off' );
    my @ran;
    for my $stage (qw[install gather]) {
        $b->register_hook( $stage => sub { push @ran, $stage } );
    }
    ok $b->has_hook('install'), 'register_hook/has_hook agree';
    ok !$b->has_hook('probe'),  'unregistered stage has no hooks';
    like dies {
        $b->register_hook( bogus => sub { } )
    }, qr/Unknown stage/, 'bad stage dies';
    $b->run;
    is \@ran, [qw[install gather]], 'hooks fired in stage order';
};
done_testing;
