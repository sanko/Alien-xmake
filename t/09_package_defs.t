use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Alien::Xrepo::Base;
use Alien::Xrepo;
use experimental 'class';

# A spy repo records the (name, version, opts) each install call gets instead of
# talking to xrepo, so the per-package def merging can be verified offline.
class Alien::Xrepo::TestSpy {
    field $calls : param = [];

    method install ( $name, $version, %opts ) {
        push @$calls, { name => $name, version => $version, opts => {%opts} };
        return Alien::Xrepo::PackageInfo->new(
            includedirs => [],
            libfiles    => [],
            license     => undef,
            linkdirs    => [],
            links       => [],
            shared      => 1,
            static      => 0,
            version     => $version // '9.9.9',
            installdir  => '/tmp/fake-install',
        );
    }
    method calls () { return $calls }
}

# Mixed family: one plain name, one fully-specified library, one flag-only tool.
class Alien::Xrepo::TestMixed : isa(Alien::Xrepo::Base) {

    method pkg_name {
        return [
            'zstd',
            { name => 'libsdl3', version => '3.4.12', kind => 'shared', configs => { wayland => 1 } },
            { name => 'ninja',   kind    => 'binary' },
        ];
    }
}

# Normalization collapses pkg_name entries into names + defs without installing.
subtest 'normalization' => sub {
    my $a = Alien::Xrepo::TestMixed->new( repo => Alien::Xrepo::TestSpy->new );
    is [ $a->package_names ], [qw[zstd libsdl3 ninja]], 'package_names are normalized, in order';
    my $defs = $a->package_defs;
    is ref $defs, 'HASH', 'package_defs is a hashref';
    ok !exists $defs->{zstd}, 'plain name carries no def';
    is $defs->{libsdl3}{version},          '3.4.12', 'def captures version';
    is $defs->{libsdl3}{kind},             'shared', 'def captures kind';
    is $defs->{libsdl3}{configs}{wayland}, 1,        'def captures nested recipe configs';
    is $defs->{ninja}{kind},               'binary', 'flag-only def captured';
    ok !exists $defs->{ninja}{version}, 'flag-only def has no version';
    my $plain = Alien::Xrepo::TestMixed->new( pkg_name => 'zstd', repo => Alien::Xrepo::TestSpy->new );
    is [ $plain->package_names ], ['zstd'], 'constructor param still wins over the pkg_name method';
    is $plain->package_defs, {}, 'plain scalar pkg_name yields empty defs';
};
subtest 'install merges per-package defs over opts' => sub {
    my $mock = Alien::Xrepo::TestSpy->new();
    my $a    = Alien::Xrepo::TestMixed->new( repo => $mock );
    $a->install( kind => 'static', configs => { zlib => 0, wayland => 0 } );
    my $calls = $mock->calls;
    is scalar @$calls, 3, 'one install call per package';
    my $zstd = $calls->[0];
    is $zstd->{name},                   'zstd',   'first call is the plain package';
    is $zstd->{version},                undef,    'plain package uses no version';
    is $zstd->{opts}{kind},             'static', 'plain package inherits global kind';
    is $zstd->{opts}{configs}{zlib},    0,        'plain package inherits global configs';
    is $zstd->{opts}{configs}{wayland}, 0,        'plain package inherits global configs untouched';
    my $sdl = $calls->[1];
    is $sdl->{name},                   'libsdl3', 'second call is the hashref library';
    is $sdl->{version},                '3.4.12',  'per-package version is used';
    is $sdl->{opts}{kind},             'shared',  'per-package kind overrides the global kind';
    is $sdl->{opts}{configs}{zlib},    0,         'global configs preserved';
    is $sdl->{opts}{configs}{wayland}, 1,         'per-package config wins per-key';
    my $ninja = $calls->[2];
    is $ninja->{name},       'ninja',  'third call is the tool';
    is $ninja->{version},    undef,    'flag-only def has no version';
    is $ninja->{opts}{kind}, 'binary', 'per-package kind for the tool';
};
subtest 'version_constraint interacts with per-package versions' => sub {
    my $mock = Alien::Xrepo::TestSpy->new;
    my $a    = Alien::Xrepo::TestMixed->new( repo => $mock, version_constraint => '1.2.3' );
    $a->install;
    my $calls = $mock->calls;
    is $calls->[0]{version}, '1.2.3',  'constraint applies to plain names';
    is $calls->[1]{version}, '3.4.12', 'per-package version beats the constraint';
    is $calls->[2]{version}, '1.2.3',  'constraint applies to flag-only defs';
};
subtest 'bad pkg_name defs die loudly' => sub {

    class Alien::Xrepo::BadUnknown : isa(Alien::Xrepo::Base) {
        method pkg_name { [ { name => 'zstd', foo => 1 } ] }
    }
    my $err = dies { Alien::Xrepo::BadUnknown->new };
    like $err, qr/unknown key 'foo'/, 'unknown top-level key dies';
    like $err, qr/configs => \{/,     'die mentions the configs nesting rule';

    class Alien::Xrepo::BadNoName : isa(Alien::Xrepo::Base) {
        method pkg_name { [ { kind => 'shared' } ] }
    }
    like dies { Alien::Xrepo::BadNoName->new }, qr/requires a 'name' key/, 'missing name dies';

    class Alien::Xrepo::BadConfigs : isa(Alien::Xrepo::Base) {
        method pkg_name { [ { name => 'zstd', configs => 'wayland=1' } ] }
    }
    like dies { Alien::Xrepo::BadConfigs->new }, qr/configs must be a hashref/, 'non-hashref configs dies';

    class Alien::Xrepo::BadEntry : isa(Alien::Xrepo::Base) {
        method pkg_name { [42] }
    }
    like dies { Alien::Xrepo::BadEntry->new }, qr/must be a package name or a hashref/, 'non-string entry dies';
};
done_testing;
