use v5.40;
use blib;
use Test2::V0 '!subtest', -no_srand => 1;
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use experimental 'class';
use Alien::Xrepo;
use Path::Tiny;
#
my $repo = Alien::Xrepo->new( verbose => 0, cache => 0 );
subtest '_cache_key is deterministic and option-sensitive' => sub {
    my $a = $repo->_cache_key( 'webui', { kind => 'shared', configs => { shared => true } } );
    my $b = $repo->_cache_key( 'webui', { kind => 'shared', configs => { shared => true } } );
    is $a,   $b, 'same spec+opts yield the same key';
    isnt $a, $repo->_cache_key( 'webui',       { kind => 'static' } ),                    'kind changes the key';
    isnt $a, $repo->_cache_key( 'webui 2.4.2', { kind => 'shared' } ),                    'version changes the key';
    isnt $a, $repo->_cache_key( 'webui',       { kind => 'shared', plat => 'windows' } ), 'plat changes the key';
    isnt $a, $repo->_cache_key( 'webui',       { kind => 'shared', arch => 'arm64' } ),   'arch changes the key';
    is $a, $repo->_cache_key( 'webui', { kind => 'shared', configs => { shared => 'true' } } ),
        'built-in boolean and the literal string hash identical (stable bool stringification)';
    isnt $a, $repo->_cache_key( 'webui', { kind => 'shared', mode => 'debug' } ), 'mode changes the key';
};
subtest 'LRU eviction drops the least recently used entry' => sub {
    my $meta = { order => [], entries => {} };
    $repo->_cache_put( 'a', $meta, { installdir => 'x', last_used => time }, 3 );
    $repo->_cache_put( 'b', $meta, { installdir => 'x', last_used => time }, 3 );
    $repo->_cache_put( 'c', $meta, { installdir => 'x', last_used => time }, 3 );
    is [ @{ $meta->{order} } ], [qw[c b a]], 'newest entries are first';
    $repo->_cache_put( 'a', $meta, $meta->{entries}{a}, 3 );
    is [ @{ $meta->{order} } ], [qw[a c b]], 're-putting an entry bumps it to the front';
    $repo->_cache_put( 'd', $meta, { installdir => 'x', last_used => time }, 3 );
    is [ @{ $meta->{order} } ], [qw[d a c]], 'overflow evicts the LRU tail (b)';
    ok !exists $meta->{entries}{b}, 'b was evicted from entries';
    ok exists $meta->{entries}{d},  'd survives';
};
subtest 'cache get bumps LRU order and rejects dead install dirs' => sub {
    my $tmp  = Path::Tiny->tempdir;
    my $live = $tmp->child('inst');
    $live->mkpath;
    my $meta = { order => [qw[a b]], entries => { a => { installdir => "$tmp/gone" }, b => { installdir => "$live" } }, };
    ok !$repo->_cache_get( 'a',  $meta ), 'missing install dir rejects a hit';
    ok !$repo->_cache_get( 'zz', $meta ), 'unknown key misses';
    ok $repo->_cache_get( 'b',   $meta ), 'present install dir is a hit';
    is [ @{ $meta->{order} } ], [qw[b a]], 'hit promoted b to the front';
};
subtest 'cache save/load round-trips and prunes stale entries' => sub {
    my $store = Path::Tiny->tempdir;
    my $live  = $store->child( 'pkgs', 'webui', 'bin' );
    $live->mkpath;
    my $meta = { order => [], entries => {} };
    $repo->_cache_put( 'live', $meta, { installdir => "$live",     json => '{"a":1}',       last_used => time }, 10 );
    $repo->_cache_put( 'dead', $meta, { installdir => "$store/zz", json => '{"gone":1}',    last_used => time }, 10 );
    $repo->_cache_put( 'raw',  $meta, { libpath    => "$store/zz", json => '{"libgone":1}', last_used => time }, 10 );
    $repo->_cache_save( $meta, installdir => "$store" );
    my $loaded = $repo->_cache_load( installdir => "$store" );
    is [ @{ $loaded->{order} } ],      ['live'],  'stale installdir/libpath entries pruned on save';
    is $loaded->{entries}{live}{json}, '{"a":1}', 'entry json round-trips';
    ok !exists $loaded->{entries}{dead},     'dead installdir entry dropped';
    ok !exists $loaded->{entries}{raw},      'dead libpath entry dropped';
    ok $repo->_cache_get( 'live', $loaded ), 'recorded dir still on disk is a valid hit';
};
subtest '_cache_entry captures install dir and first lib' => sub {
    my $entry = $repo->_cache_entry( { artifacts => { installdir => 'C:/pkg/root' }, libfiles => ['C:/pkg/root/lib/webui.lib'] } );
    is $entry->{installdir}, 'C:/pkg/root',               'install dir taken from artifacts';
    is $entry->{libpath},    'C:/pkg/root/lib/webui.lib', 'first lib recorded for validation';
    ok exists $entry->{json}, 'raw json kept for replay';
};
subtest '_info_installed distinguishes installed vs not' => sub {
    my $tmp = Path::Tiny->tempdir;
    my $bin = $tmp->child('bin');
    my $lib = $tmp->child('lib');
    $bin->mkpath;
    $lib->mkpath;
    $lib->child('webui.lib')->spew('x');
    $bin->child('ninja.exe')->spew('x');
    ok $repo->_info_installed( { bindirs    => ["$bin"] } ),                      'existing bindir counts as installed';
    ok !$repo->_info_installed( { bindirs   => ["$tmp/nope"] } ),                 'missing bindir does not';
    ok $repo->_info_installed( { libfiles   => ["$lib/webui.lib"] } ),            'existing libfile counts as installed';
    ok !$repo->_info_installed( { libfiles  => [] } ),                            'empty file list does not';
    ok $repo->_info_installed( { artifacts  => { installdir => "$tmp" } } ),      'existing install root counts';
    ok !$repo->_info_installed( { artifacts => { installdir => "$tmp/nope" } } ), 'missing install root does not';
    ok !$repo->_info_installed( {} ), 'empty record is not installed';
};
#
done_testing;
